import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../tracer_client.dart';
import '../tracer_dsn.dart';
import 'gzip.dart';
import 'wire.dart';

/// First back-off after a failed send; doubles up to [_maxBackoff].
const Duration _baseBackoff = Duration(seconds: 1);
const Duration _maxBackoff = Duration(minutes: 5);

/// The ingest's quota refusal says 300 s; used when a 429 has no usable
/// `Retry-After`.
const Duration _defaultQuotaWait = Duration(seconds: 300);

/// The longest `Retry-After` honoured.
const Duration _maxRetryAfter = Duration(days: 1);

final class _Queued {
  _Queued(this.body, this.kind);
  final Uint8List body;
  final String kind;
}

/// The one [TracerClient] implementation.
final class TracerClientImpl implements TracerClient {
  /// Parses the DSN; an empty or bad one leaves the client [TracerState.off].
  TracerClientImpl(TracerOptions options)
    : _options = options,
      _logger = options.logger ?? nullLogger,
      _now = options.now ?? DateTime.now,
      _random = options.random ?? _secureRandom(),
      _tags = Map.fromEntries(options.tags.entries.take(TracerLimits.maxTags)),
      _release = _nonEmpty(options.release),
      _dist = _nonEmpty(options.dist),
      _environment = _nonEmpty(options.environment),
      _userId = _nonEmpty(options.userId),
      _breadcrumbCapacity = options.breadcrumbCapacity.clamp(
        0,
        TracerLimits.maxBreadcrumbs,
      ),
      _logBatchSize = options.logBatchSize.clamp(
        1,
        TracerLimits.maxLogsPerContainer,
      ),
      _compress = options.compress && gzipAvailable {
    traceId = hexId(_random, 16);
    if (options.dsn.trim().isEmpty) {
      _state = TracerState.off;
      return;
    }
    final dsn = TracerDsn.tryParse(
      options.dsn,
      allowHttpLoopback: options.allowHttpLoopback,
    );
    if (dsn == null) {
      _state = TracerState.off;
      _diag(LogSeverity.warn, 'tracer off: DSN did not parse');
      return;
    }
    _dsn = dsn;
    _auth =
        'Sentry sentry_key=${dsn.writeKey}, sentry_version=7, '
        'sentry_client=yyt-dart/$tracerSdkVersion';
    _client = options.client ?? http.Client();
    _ownsClient = options.client == null;
    _state = TracerState.active;
    _diag(LogSeverity.info, 'tracer active', {'resource': dsn.resourceId});
  }

  final TracerOptions _options;
  final Logger _logger;
  final DateTime Function() _now;
  final Random _random;
  final Map<String, String> _tags;
  final String? _release;
  final String? _dist;
  final String? _environment;
  final String? _userId;
  final int _breadcrumbCapacity;
  final int _logBatchSize;
  bool _compress;

  TracerState _state = TracerState.off;
  TracerDsn? _dsn;
  String _auth = '';
  http.Client? _client;
  bool _ownsClient = false;

  @override
  late final String traceId;

  final ListQueue<Map<String, Object?>> _breadcrumbs = ListQueue();
  final List<Uint8List> _logs = [];
  int _logBytes = 0;
  Timer? _logTimer;

  final ListQueue<_Queued> _queue = ListQueue();
  int _queuedBytes = 0;
  bool _sending = false;
  Timer? _resumeTimer;
  int _failures = 0;
  final List<Completer<void>> _idleWaiters = [];
  Completer<void>? _abort;

  int _sent = 0;
  final Map<String, int> _dropped = {};
  bool _inDiag = false;

  static String? _nonEmpty(String? v) => v == null || v.isEmpty ? null : v;

  static Random _secureRandom() {
    try {
      return Random.secure();
    } on UnsupportedError {
      return Random();
    }
  }

  @override
  TracerState get state => _state;

  @override
  bool get enabled => _state == TracerState.active;

  @override
  TracerStats get stats => TracerStats(
    envelopesSent: _sent,
    queued: _queue.length,
    dropped: Map.unmodifiable(_dropped),
  );

  void _drop(String reason, [int count = 1]) {
    if (count <= 0) return;
    _dropped[reason] = (_dropped[reason] ?? 0) + count;
  }

  void _diag(
    LogSeverity severity,
    String message, [
    Map<String, Object?>? context,
  ]) {
    if (_inDiag) return;
    _inDiag = true;
    try {
      switch (severity) {
        case LogSeverity.debug:
          _logger.debug(message, context);
        case LogSeverity.info:
          _logger.info(message, context);
        case LogSeverity.warn:
          _logger.warn(message, context);
        case LogSeverity.error || LogSeverity.none:
          _logger.error(message, context);
      }
    } on Object {
      // A broken writer is not the tracer's failure to report.
    } finally {
      _inDiag = false;
    }
  }

  /// Runs [body] unless off or re-entered from the client's own logger, and
  /// turns any failure into a count.
  T? _guard<T>(T? Function() body) {
    if (_state != TracerState.active || _inDiag) return null;
    try {
      return body();
    } on Object catch (error) {
      _drop('internal');
      _diag(LogSeverity.warn, 'tracer internal error', {
        'type': error.runtimeType.toString(),
      });
      return null;
    }
  }

  @override
  void setTag(String key, String? value) {
    _guard(() {
      final k = clipUtf8(key, 200);
      if (value == null) {
        _tags.remove(k);
      } else if (_tags.containsKey(k) || _tags.length < TracerLimits.maxTags) {
        _tags[k] = clipUtf8(value, 200);
      }
    });
  }

  @override
  void breadcrumb(
    String category,
    String message, {
    Map<String, Object?>? data,
    TracerLevel level = TracerLevel.info,
  }) {
    _guard(() {
      if (_breadcrumbCapacity == 0) return;
      final safe = data == null ? null : _capData(jsonSafe(data));
      _breadcrumbs.add({
        'timestamp': rfc3339(_now()),
        'type': 'default',
        'category': clipUtf8(category, 200),
        'level': eventLevel(level),
        'message': clipUtf8(message, TracerLimits.maxTextBytes),
        if (safe is Map && safe.isNotEmpty) 'data': safe,
      });
      while (_breadcrumbs.length > _breadcrumbCapacity) {
        _breadcrumbs.removeFirst();
      }
    });
  }

  @override
  void log(
    TracerLevel level,
    String message, {
    Map<String, Object?>? attributes,
  }) {
    _guard(() {
      final attrs = <String, Object?>{..._baseAttributes()};
      // The ingest keeps a line's attributes only up to 16 KiB of JSON, all
      // or nothing: the base ones first, then the caller's while they fit.
      var size = jsonBytes(attrs).length;
      var cut = false;
      for (final e in (attributes ?? const <String, Object?>{}).entries) {
        final typed = typedAttribute(e.value);
        if (typed == null) continue;
        final key = clipUtf8(e.key, 200);
        final add = jsonBytes({key: typed}).length;
        if (size + add > TracerLimits.maxDataBytes - 64) {
          cut = true;
          continue;
        }
        attrs[key] = typed;
        size += add;
      }
      if (cut) attrs['tracer.truncated'] = {'value': true, 'type': 'boolean'};
      final entry = jsonBytes({
        'timestamp': epochSeconds(_now()),
        'trace_id': traceId,
        'level': logLevel(level),
        'body': clipUtf8(message, TracerLimits.maxTextBytes),
        'severity_number': severityNumber(level),
        'attributes': attrs,
      });
      _logs.add(entry);
      _logBytes += entry.length + 1;
      if (_logs.length >= _logBatchSize ||
          _logBytes >= TracerLimits.maxJsonItemBytes ~/ 2) {
        _flushLogs();
        _kick();
      } else {
        _logTimer ??= Timer(_options.flushInterval, () {
          _logTimer = null;
          _guard(() {
            _flushLogs();
            _kick();
          });
        });
      }
    });
  }

  @override
  void trace(
    String category,
    String message, {
    Map<String, Object?>? data,
    TracerLevel level = TracerLevel.info,
  }) {
    breadcrumb(category, message, data: data, level: level);
    log(level, message, attributes: {'category': category, ...?data});
  }

  Map<String, Object?> _baseAttributes() {
    Map<String, Object?> str(String v) => {'value': v, 'type': 'string'};
    final device = _options.contexts['device'];
    final model = device is Map ? device['model'] : null;
    return {
      'sentry.sdk.name': str(sdkInfo['name']!),
      'sentry.sdk.version': str(tracerSdkVersion),
      if (_release case final r?) 'sentry.release': str(r),
      if (_environment case final e?) 'sentry.environment': str(e),
      if (_dist case final d?) 'sentry.dist': str(d),
      if (_userId case final u?) 'user.id': str(u),
      if (model is String && model.isNotEmpty)
        'device.model': str(clipUtf8(model, 200)),
      for (final t in _tags.entries) t.key: str(t.value),
    };
  }

  /// [data] as is when its JSON fits what the ingest keeps, else a marker.
  static Object? _capData(Object? data) =>
      data != null && jsonBytes(data).length > TracerLimits.maxDataBytes
      ? {'tracer.truncated': true}
      : data;

  Map<String, Object?> _eventBase(String eventId, TracerLevel level) => {
    'event_id': eventId,
    'timestamp': rfc3339(_now()),
    'platform': 'dart',
    'level': eventLevel(level),
    'release': ?_release,
    'dist': ?_dist,
    'environment': ?_environment,
    if (_tags.isNotEmpty) 'tags': Map.of(_tags),
    if (_userId case final u?) 'user': {'id': u},
  };

  Map<String, Object?> _contexts(Map<String, Object?> own) {
    final extra = jsonSafe(_options.contexts);
    return {
      if (extra is Map<String, Object?>)
        for (final e in extra.entries)
          if (e.key != 'trace' && e.key != 'feedback') e.key: e.value,
      'trace': {'trace_id': traceId, 'span_id': hexId(_random, 8)},
      ...own,
    };
  }

  /// The event payload, trimmed under the JSON item cap: oldest breadcrumbs
  /// first, then `extra`, then the exception. Null when it still does not
  /// fit (its attachments would be stored without an event).
  Uint8List? _eventPayload(Map<String, Object?> event) {
    const cap = TracerLimits.maxJsonItemBytes - itemOverhead;
    var payload = jsonBytes(event);
    final crumbs = (event['breadcrumbs'] as Map?)?['values'] as List?;
    while (payload.length > cap && crumbs != null && crumbs.isNotEmpty) {
      crumbs.removeRange(0, (crumbs.length + 1) ~/ 2);
      payload = jsonBytes(event);
    }
    for (final key in ['extra', 'exception']) {
      if (payload.length <= cap) break;
      event.remove(key);
      payload = jsonBytes(event);
    }
    return payload.length <= cap ? payload : null;
  }

  @override
  Future<String?> report(
    String message, {
    Map<String, Object?>? data,
    Uint8List? screenshot,
    List<TracerAttachment> attachments = const [],
    Object? error,
    StackTrace? stackTrace,
    TracerLevel level = TracerLevel.warning,
  }) async {
    final id = _guard(() {
      final eventId = hexId(_random, 16);
      final safeData = data == null ? null : _capData(jsonSafe(data));
      final event = <String, Object?>{
        ..._eventBase(eventId, level),
        'message': clipUtf8(message, TracerLimits.maxTextBytes),
        'contexts': _contexts(const {}),
        if (safeData is Map && safeData.isNotEmpty) 'extra': safeData,
        if (error != null) 'exception': _exception(error, stackTrace),
        'breadcrumbs': {'values': _breadcrumbs.toList()},
        'sdk': sdkInfo,
      };
      final payload = _eventPayload(event);
      if (payload == null) {
        _drop('too_large');
        return null;
      }
      final items = [
        WireItem({'type': 'event'}, payload),
      ];
      var json = items.first.payload.length + itemOverhead;
      final logs = _takeLogs(TracerLimits.maxJsonBytesPerEnvelope - json);
      if (logs != null) {
        items.add(logs);
        json += logs.payload.length + itemOverhead;
      }
      // Margin for gzip framing: PNG does not compress, and the ingest caps
      // the body as sent too.
      var room = TracerLimits.maxEnvelopeBytes - 64 * 1024 - json;
      final files = [
        if (screenshot != null) TracerAttachment.screenshot(screenshot),
        ...attachments,
      ];
      var count = 0;
      for (final file in files) {
        final size = file.bytes.length + itemOverhead;
        if (count == TracerLimits.maxAttachmentsPerEnvelope || size > room) {
          _drop('too_large');
          continue;
        }
        items.add(
          WireItem({
            'type': 'attachment',
            'filename': clipUtf8(file.filename, 200),
            'content_type': clipUtf8(file.contentType, 100),
            'attachment_type': clipUtf8(file.attachmentType, 64),
          }, file.bytes),
        );
        room -= size;
        count++;
      }
      _enqueue(_envelope(eventId, items), 'event');
      _flushLogs();
      _kick();
      return eventId;
    });
    return id;
  }

  Map<String, Object?> _exception(Object error, StackTrace? stackTrace) {
    final frames = stackTrace == null
        ? const <Map<String, Object?>>[]
        : stackFrames(stackTrace);
    String value;
    try {
      value = error.toString();
    } on Object {
      value = '<unprintable>';
    }
    return {
      'values': [
        {
          'type': error.runtimeType.toString(),
          'value': clipUtf8(value, TracerLimits.maxTextBytes),
          if (frames.isNotEmpty) 'stacktrace': {'frames': frames},
        },
      ],
    };
  }

  @override
  Future<String?> feedback(String note, {String? eventId}) async {
    return _guard(() {
      final id = hexId(_random, 16);
      final associated = eventId?.replaceAll('-', '').toLowerCase();
      final event = <String, Object?>{
        ..._eventBase(id, TracerLevel.info),
        'contexts': _contexts({
          'feedback': {
            'message': clipUtf8(note, TracerLimits.maxTextBytes),
            if (associated != null &&
                RegExp(r'^[0-9a-f]{32}$').hasMatch(associated))
              'associated_event_id': associated,
          },
        }),
        'sdk': sdkInfo,
      };
      final payload = _eventPayload(event);
      if (payload == null) {
        _drop('too_large');
        return null;
      }
      _enqueue(
        _envelope(id, [
          WireItem({'type': 'feedback'}, payload),
        ]),
        'feedback',
      );
      _kick();
      return id;
    });
  }

  Uint8List _envelope(String? eventId, List<WireItem> items) => encodeEnvelope({
    'event_id': ?eventId,
    'sent_at': rfc3339(_now()),
    'sdk': sdkInfo,
  }, items);

  /// One log container from the oldest buffered lines that fit [budget]
  /// bytes (and the per-item caps); null when nothing is buffered or fits.
  WireItem? _takeLogs(int budget) {
    final cap = min(budget, TracerLimits.maxJsonItemBytes) - itemOverhead;
    var size = '{"items":[]}'.length;
    var n = 0;
    while (n < _logs.length &&
        n < TracerLimits.maxLogsPerContainer &&
        size + _logs[n].length + 1 <= cap) {
      size += _logs[n].length + 1;
      n++;
    }
    if (n == 0) return null;
    final taken = _logs.sublist(0, n);
    _logs.removeRange(0, n);
    _logBytes = _logs.fold(0, (sum, e) => sum + e.length + 1);
    if (_logs.isEmpty) {
      _logTimer?.cancel();
      _logTimer = null;
    }
    final out = BytesBuilder(copy: false)..add(utf8.encode('{"items":['));
    for (var i = 0; i < taken.length; i++) {
      if (i > 0) out.addByte(0x2C);
      out.add(taken[i]);
    }
    out.add(utf8.encode(']}'));
    return WireItem({
      'type': 'log',
      'item_count': taken.length,
      'content_type': logContentType,
    }, out.takeBytes());
  }

  /// Moves every buffered log line into envelopes of their own.
  void _flushLogs() {
    _logTimer?.cancel();
    _logTimer = null;
    while (_logs.isNotEmpty) {
      final item = _takeLogs(TracerLimits.maxJsonItemBytes);
      if (item == null) {
        // A single line over the cap cannot be sent.
        _logBytes -= _logs.removeAt(0).length + 1;
        _drop('too_large');
        continue;
      }
      _enqueue(_envelope(null, [item]), 'log');
    }
  }

  void _enqueue(Uint8List body, String kind) {
    _queue.add(_Queued(body, kind));
    _queuedBytes += body.length;
    _trimQueue();
  }

  /// Drops the oldest envelopes past either bound, keeping at least one.
  void _trimQueue() {
    while (_queue.length > 1 &&
        (_queue.length > _options.maxQueuedEnvelopes ||
            _queuedBytes > _options.maxQueuedBytes)) {
      _queuedBytes -= _queue.removeFirst().body.length;
      _drop('queue_full');
    }
  }

  bool get _paused => _resumeTimer != null;

  void _kick() {
    if (_sending || _paused || _state != TracerState.active) {
      _settleIdle();
      return;
    }
    if (_queue.isEmpty) {
      _settleIdle();
      return;
    }
    _sending = true;
    unawaited(_run());
  }

  void _settleIdle() {
    if (_sending) return;
    for (final w in _idleWaiters) {
      if (!w.isCompleted) w.complete();
    }
    _idleWaiters.clear();
  }

  Future<void> _run() async {
    try {
      while (_queue.isNotEmpty && !_paused && _state == TracerState.active) {
        final next = _queue.removeFirst();
        _queuedBytes -= next.body.length;
        final retry = await _send(next);
        if (retry != null) {
          _queue.addFirst(next);
          _queuedBytes += next.body.length;
          _trimQueue();
          if (retry > Duration.zero) _pause(retry);
        }
      }
    } on Object catch (error) {
      _drop('internal');
      _diag(LogSeverity.warn, 'tracer send loop failed', {
        'type': error.runtimeType.toString(),
      });
    } finally {
      _sending = false;
      _settleIdle();
    }
  }

  void _pause(Duration wait) {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(wait, () {
      _resumeTimer = null;
      _kick();
    });
  }

  Duration _backoff() {
    final shift = min(_failures, 9);
    _failures++;
    final ms = min(
      _baseBackoff.inMilliseconds << shift,
      _maxBackoff.inMilliseconds,
    );
    return Duration(
      milliseconds: (ms * (0.5 + 0.5 * _random.nextDouble())).round(),
    );
  }

  static Duration? _retryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    // Zero would resend at once, forever: treat it as absent.
    if (seconds == null || seconds <= 0) return null;
    final wait = Duration(seconds: seconds);
    return wait > _maxRetryAfter ? _maxRetryAfter : wait;
  }

  /// Sends one envelope. Returns null when it is done with (sent or
  /// dropped), else how long to wait before trying it again (zero: now).
  Future<Duration?> _send(_Queued item) async {
    final dsn = _dsn!;
    final abort = _abort = Completer<void>();
    final compress = _compress;
    final request =
        http.AbortableRequest(
            'POST',
            dsn.envelopeUri,
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers['content-type'] = 'application/x-sentry-envelope'
          ..headers['x-sentry-auth'] = _auth
          ..bodyBytes = compress ? gzipBytes(item.body) : item.body;
    if (compress) request.headers['content-encoding'] = 'gzip';
    int status;
    String? retryAfter;
    try {
      final response = await _exchange(
        request,
      ).timeout(_options.timeout + Duration(seconds: item.body.length >> 16));
      status = response.$1;
      retryAfter = response.$2;
    } on Object catch (error) {
      if (!abort.isCompleted) abort.complete();
      if (_state != TracerState.active) {
        _drop('closed');
        return null;
      }
      final wait = _backoff();
      _diag(LogSeverity.debug, 'tracer send failed', {
        'type': error.runtimeType.toString(),
        'kind': item.kind,
        'retryMs': wait.inMilliseconds,
      });
      return wait;
    } finally {
      _abort = null;
    }
    if (!abort.isCompleted) abort.complete();
    _diag(LogSeverity.debug, 'tracer envelope', {
      'kind': item.kind,
      'status': status,
      'bytes': item.body.length,
    });
    if (status >= 200 && status < 300) {
      _sent++;
      _failures = 0;
      return null;
    }
    switch (status) {
      case 401:
        _stop();
        _drop('unauthorized', 1 + _queue.length);
        _queue.clear();
        _queuedBytes = 0;
        return null;
      case 429:
        return _retryAfter(retryAfter) ?? _defaultQuotaWait;
      case 400:
        _drop('invalid');
        return null;
      case 413:
        _drop('too_large');
        return null;
      case 415 when compress:
        _compress = false;
        return Duration.zero;
      case 415:
        _drop('encoding');
        return null;
      case >= 500:
        return _retryAfter(retryAfter) ?? _backoff();
      default:
        _drop('http_$status');
        return null;
    }
  }

  Future<(int, String?)> _exchange(http.BaseRequest request) async {
    final response = await _client!.send(request);
    // The answer is `{"id"}` or `{"detail"}`; nothing in it is needed.
    await response.stream.drain<void>();
    return (response.statusCode, response.headers['retry-after']);
  }

  void _stop() {
    _state = TracerState.stopped;
    _diag(LogSeverity.warn, 'tracer stopped: the ingest refused the key', {
      'resource': _dsn?.resourceId,
    });
    _shutdown();
  }

  void _shutdown() {
    _logTimer?.cancel();
    _logTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _drop('closed', _logs.length);
    _logs.clear();
    _logBytes = 0;
    _breadcrumbs.clear();
  }

  @override
  Future<void> flush() async {
    if (_state != TracerState.active) return;
    try {
      _flushLogs();
      if (_paused || (_queue.isEmpty && !_sending)) return;
      final idle = Completer<void>();
      _idleWaiters.add(idle);
      _kick();
      await idle.future;
    } on Object {
      _drop('internal');
    }
  }

  @override
  Future<void> close() async {
    if (_state == TracerState.closed) return;
    if (_state == TracerState.active) {
      try {
        await flush().timeout(_options.timeout);
      } on Object {
        // Bounded: whatever is left is counted below.
      }
    }
    _state = TracerState.closed;
    _shutdown();
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _drop('closed', _queue.length);
    _queue.clear();
    _queuedBytes = 0;
    _settleIdle();
    if (_ownsClient) _client?.close();
  }
}
