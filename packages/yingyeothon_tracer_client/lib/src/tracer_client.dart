import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'internal/tracer_client_impl.dart';

/// The version this library reports in the envelope header (`sdk.version`)
/// and in `X-Sentry-Auth` (`sentry_client=yyt-dart/<version>`).
const String tracerSdkVersion = '0.3.0';

/// Severity of a breadcrumb, a log line or a report.
///
/// On the wire an event says `warning` and a log line says `warn`, with the
/// matching `severity_number`; the library writes each.
enum TracerLevel {
  /// Diagnostic detail.
  debug,

  /// Milestones.
  info,

  /// Something looked wrong; the default level of [TracerClient.report].
  warning,

  /// A failure.
  error,

  /// A failure the app cannot continue from.
  fatal,
}

/// Where a client stands.
enum TracerState {
  /// Sending: the DSN parsed and the ingest has not refused the key.
  active,

  /// Never sending: the DSN was empty or did not parse. Every call is a
  /// no-op.
  off,

  /// The ingest answered `401`: the key is wrong or rotated. Nothing more is
  /// sent until the app builds a new client with a new DSN.
  stopped,

  /// [TracerClient.close] ran.
  closed,
}

/// Limits the client keeps under, from the service's tracer ingest
/// (`docs/tracer.md`, _Wire contract for client libraries_ and _Ingest_).
/// Every size is UTF-8 bytes.
abstract final class TracerLimits {
  /// The ingest refuses a body over 20 MiB, compressed or not; the client
  /// keeps the uncompressed envelope at or under this.
  static const int maxEnvelopeBytes = 20 * 1024 * 1024;

  /// Each JSON item (event, feedback, log container) is dropped by the
  /// ingest over 1 MiB.
  static const int maxJsonItemBytes = 1024 * 1024;

  /// JSON items one envelope may hold until the ingest commits it.
  static const int maxJsonBytesPerEnvelope = 2 * 1024 * 1024;

  /// Entries in one log container (the ingest stores the first 1000).
  static const int maxLogsPerContainer = 1000;

  /// Attachments per envelope.
  static const int maxAttachmentsPerEnvelope = 20;

  /// Breadcrumbs the ingest keeps per event; the default ring size.
  static const int maxBreadcrumbs = 500;

  /// Text the ingest keeps of a message, log body or breadcrumb message.
  static const int maxTextBytes = 8 * 1024;

  /// A log line's attributes, a breadcrumb's `data` or a report's `extra`
  /// as JSON: the ingest keeps (or shows) them only up to this.
  static const int maxDataBytes = 16 * 1024;

  /// Tags the ingest keeps per event.
  static const int maxTags = 64;
}

/// A file sent with a report, stored by tracer and readable with
/// `yyt tracer attachments`.
final class TracerAttachment {
  /// A file with an explicit [filename], [contentType] and
  /// [attachmentType] (the Sentry `attachment_type`).
  const TracerAttachment({
    required this.filename,
    required this.bytes,
    this.contentType = 'application/octet-stream',
    this.attachmentType = 'event.attachment',
  });

  /// A PNG screenshot, `screenshot.png`, as Sentry SDKs name it.
  const TracerAttachment.screenshot(Uint8List png)
    : this(filename: 'screenshot.png', bytes: png, contentType: 'image/png');

  /// A view-hierarchy JSON document (`event.view_hierarchy`).
  const TracerAttachment.viewHierarchy(Uint8List json)
    : this(
        filename: 'view-hierarchy.json',
        bytes: json,
        contentType: 'application/json',
        attachmentType: 'event.view_hierarchy',
      );

  /// File name shown by the read API (no directory).
  final String filename;

  /// The bytes, sent as they are.
  final Uint8List bytes;

  /// MIME type.
  final String contentType;

  /// `event.attachment`, `event.view_hierarchy`, `event.minidump`, …
  final String attachmentType;
}

/// Counters a client keeps; a snapshot, so read it again for fresh values.
final class TracerStats {
  /// Builds a snapshot.
  const TracerStats({
    required this.envelopesSent,
    required this.queued,
    required this.dropped,
  });

  /// Envelopes the ingest answered `200`.
  final int envelopesSent;

  /// Envelopes waiting to be sent.
  final int queued;

  /// Things the client gave up on, by reason: `too_large` (`413`, or split
  /// past a limit), `invalid` (`400`), `encoding` (`415`), `unauthorized`
  /// (`401`), `queue_full` (the oldest envelope made room), `http_<status>`,
  /// `internal`, `closed`.
  final Map<String, int> dropped;
}

/// Options of one [TracerClient]. The client copies them at construction.
final class TracerOptions {
  /// Options for [dsn]; an empty [dsn] makes a client that is [TracerState.off].
  const TracerOptions({
    required this.dsn,
    this.release,
    this.dist,
    this.environment,
    this.tags = const {},
    this.userId,
    this.contexts = const {},
    this.client,
    this.logger,
    this.now,
    this.random,
    this.breadcrumbCapacity = TracerLimits.maxBreadcrumbs,
    this.logBatchSize = 100,
    this.flushInterval = const Duration(seconds: 5),
    this.maxQueuedEnvelopes = 32,
    this.maxQueuedBytes = 48 * 1024 * 1024,
    this.timeout = const Duration(seconds: 30),
    this.compress = true,
    this.allowHttpLoopback = false,
  });

  /// `https://{writeKey}@{host}/{trc_id}`, from `yyt tracer dsn` through a
  /// build define; never committed. Empty means off.
  final String dsn;

  /// `version+build` of the app.
  final String? release;

  /// A build discriminator; a git sha lets a reader check out the code.
  final String? dist;

  /// `debug`, `profile`, `dev`, …
  final String? environment;

  /// Tags on every event and attributes on every log line; tracer keeps 64.
  final Map<String, String> tags;

  /// `user.id` on events and logs; an installation id in debug builds, never
  /// a person's name or email.
  final String? userId;

  /// Extra event `contexts` (`device`, `os`, `app`, …); `trace` and
  /// `feedback` are the client's own.
  final Map<String, Object?> contexts;

  /// Injected HTTP client; never closed by the tracer client.
  final http.Client? client;

  /// The client's own diagnostics (ids, statuses, counts), default
  /// [nullLogger].
  final Logger? logger;

  /// Clock, default `DateTime.now`.
  final DateTime Function()? now;

  /// Source of ids and back-off jitter, default `Random.secure()`.
  final Random? random;

  /// Breadcrumbs kept for the next report, oldest dropped first.
  final int breadcrumbCapacity;

  /// Buffered log lines that trigger a send (at most
  /// [TracerLimits.maxLogsPerContainer]).
  final int logBatchSize;

  /// The longest a buffered log line waits before it is sent.
  final Duration flushInterval;

  /// Envelopes kept while the ingest is unreachable; the oldest is dropped
  /// past this.
  final int maxQueuedEnvelopes;

  /// Bytes kept while the ingest is unreachable; the oldest is dropped past
  /// this (a soft bound: the newest envelope and the one being sent stay).
  final int maxQueuedBytes;

  /// Deadline of one request, headers and body, plus one second per 64 KiB
  /// of body so a large report can finish on a slow link.
  final Duration timeout;

  /// Whether bodies are gzipped (native platforms only; web sends them
  /// plain).
  final bool compress;

  /// Allows an `http` DSN to a loopback host ([TracerDsn.parse]); off by
  /// default. Turn it on only in a debug build.
  final bool allowHttpLoopback;
}

/// A tracer client: a breadcrumb ring, buffered logs and a bounded send
/// queue in front of tracer's envelope ingest.
///
/// It never throws into the app and never blocks it: every method returns at
/// once (the futures complete when the work is queued or sent) and a failure
/// is a count in [stats]. Each isolate builds its own client.
abstract interface class TracerClient {
  /// Builds a client. A DSN that is empty or does not parse gives a client
  /// in [TracerState.off]; nothing throws.
  factory TracerClient(TracerOptions options) = TracerClientImpl;

  /// Where the client stands.
  TracerState get state;

  /// Whether calls do anything: [state] is [TracerState.active].
  bool get enabled;

  /// The `trace_id` this client puts on every event and log line.
  String get traceId;

  /// Counters since construction.
  TracerStats get stats;

  /// Adds a tag to later events and log lines; a null [value] removes it.
  /// Past [TracerLimits.maxTags] a new key is ignored.
  void setTag(String key, String? value);

  /// Remembers a step for the next report. Breadcrumbs leave the device only
  /// inside an event.
  void breadcrumb(
    String category,
    String message, {
    Map<String, Object?>? data,
    TracerLevel level = TracerLevel.info,
  });

  /// Buffers a log line; [attributes] become typed attributes. Sent by size
  /// or after [TracerOptions.flushInterval].
  void log(
    TracerLevel level,
    String message, {
    Map<String, Object?>? attributes,
  });

  /// [breadcrumb] and [log] in one call: the trail before something looks
  /// wrong, both in the report and in the timeline.
  void trace(
    String category,
    String message, {
    Map<String, Object?>? data,
    TracerLevel level = TracerLevel.info,
  });

  /// Sends an event at once with the breadcrumb ring, the buffered log lines,
  /// an optional PNG [screenshot] and other [attachments]. An [error] and
  /// [stackTrace] become an exception with frames. Completes with the event
  /// id once the envelope is queued (null when the client is not active);
  /// pass it to [feedback].
  Future<String?> report(
    String message, {
    Map<String, Object?>? data,
    Uint8List? screenshot,
    List<TracerAttachment> attachments = const [],
    Object? error,
    StackTrace? stackTrace,
    TracerLevel level = TracerLevel.warning,
  });

  /// Sends a user's [note], linked to the report [eventId] when given.
  /// Completes with the feedback's own id (null when not active).
  Future<String?> feedback(String note, {String? eventId});

  /// Sends the buffered log lines and whatever is queued. Completes when the
  /// queue is empty or waiting out a back-off; never waits for one.
  Future<void> flush();

  /// [flush], then stops. Later calls are no-ops.
  Future<void> close();
}

/// One process-wide client for code that has no place to hold one: the
/// spec's `init(dsn, …)`.
abstract final class Tracer {
  static TracerClient _current = TracerClient(const TracerOptions(dsn: ''));

  /// The client [init] built last; an off client before that.
  static TracerClient get current => _current;

  /// Builds a client for [dsn] (empty → off), makes it [current] and closes
  /// the previous one. Returns the new client.
  static TracerClient init(
    String dsn, {
    String? release,
    String? dist,
    String? environment,
    Map<String, String> tags = const {},
    String? userId,
    Map<String, Object?> contexts = const {},
    http.Client? client,
    Logger? logger,
  }) => initWith(
    TracerOptions(
      dsn: dsn,
      release: release,
      dist: dist,
      environment: environment,
      tags: tags,
      userId: userId,
      contexts: contexts,
      client: client,
      logger: logger,
    ),
  );

  /// [init] with every option.
  static TracerClient initWith(TracerOptions options) {
    final previous = _current;
    _current = TracerClient(options);
    previous.close().ignore();
    return _current;
  }
}

/// A `yingyeothon_logger` [LogWriter] that forwards every line to a tracer
/// client — [client], or [Tracer.current] at each line when it is null — as
/// a log line with the context as attributes, and with [breadcrumbs] also a
/// breadcrumb in category `log`.
///
/// Compose it with `LogWriters.combine`. Do not hand the logger it feeds to
/// the same client's [TracerOptions.logger]: the client ignores its own
/// lines, but the loop is still pointless.
final class TracerLogWriter implements LogWriter {
  /// Forwards to [client], or to [Tracer.current] when it is null.
  const TracerLogWriter({this.client, this.breadcrumbs = true});

  /// Where lines go; null means [Tracer.current] at each line.
  final TracerClient? client;

  /// Whether each line is also a breadcrumb.
  final bool breadcrumbs;

  void _write(TracerLevel level, String message, Map<String, Object?>? ctx) {
    final target = client ?? Tracer.current;
    if (breadcrumbs) {
      target.breadcrumb('log', message, data: ctx, level: level);
    }
    target.log(level, message, attributes: ctx);
  }

  @override
  void debug(String message, [Map<String, Object?>? context]) =>
      _write(TracerLevel.debug, message, context);

  @override
  void info(String message, [Map<String, Object?>? context]) =>
      _write(TracerLevel.info, message, context);

  @override
  void warn(String message, [Map<String, Object?>? context]) =>
      _write(TracerLevel.warning, message, context);

  @override
  void error(String message, [Map<String, Object?>? context]) =>
      _write(TracerLevel.error, message, context);
}
