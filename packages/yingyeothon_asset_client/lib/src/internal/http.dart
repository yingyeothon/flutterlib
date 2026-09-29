import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../errors.dart';

/// What a request was for; the only thing besides the status that is logged.
enum RequestKind {
  /// One plain `GET` of the whole file.
  whole,

  /// A `HEAD` for the length and the identity.
  head,

  /// A ranged `GET` of the 40-byte header alone.
  header,

  /// A ranged `GET` of ciphertext segments.
  segments,

  /// A ranged `GET` of a plain file.
  range,
}

/// `bytes a-b/total` or `bytes a-b/*`.
final class ContentRange {
  /// Creates a range.
  const ContentRange(this.start, this.end, this.total);

  /// First byte, inclusive.
  final int start;

  /// Last byte, inclusive.
  final int end;

  /// `null` for `bytes a-b/*`.
  final int? total;
}

final RegExp _contentRange = RegExp(
  r'^bytes (\d{1,16})-(\d{1,16})/(\d{1,16}|\*)$',
);
final RegExp _unsatisfied = RegExp(r'^bytes \*/(\d{1,16})$');
final RegExp _digits = RegExp(r'^\d{1,16}$');

/// `bytes a-b/total` or `bytes a-b/*`; anything else (including the `*/total`
/// of a 416) is `null`.
ContentRange? parseContentRange(String? raw) {
  final match = raw == null ? null : _contentRange.firstMatch(raw.trim());
  if (match == null) return null;
  final start = int.parse(match.group(1)!);
  final end = int.parse(match.group(2)!);
  final total = match.group(3) == '*' ? null : int.parse(match.group(3)!);
  if (end < start || (total != null && end >= total)) return null;
  return ContentRange(start, end, total);
}

int? _parseUnsatisfied(String? raw) {
  final match = raw == null ? null : _unsatisfied.firstMatch(raw.trim());
  return match == null ? null : int.parse(match.group(1)!);
}

int? _parseLength(String? raw) {
  if (raw == null || !_digits.hasMatch(raw.trim())) return null;
  return int.parse(raw.trim());
}

/// A strong ETag may go into `If-Range`; a weak one never matches there.
bool isStrongEtag(String? etag) =>
    etag != null && etag.isNotEmpty && !etag.startsWith('W/');

/// `http`: a body larger than any file the platform accepts.
AssetClientException tooLarge(int status) => AssetClientException(
  AssetClientErrorCode.http,
  status: status,
  detail: 'the body is larger than any asset',
);

/// `network`, with the status of the answer whose body failed.
AssetClientException networkError(int status, String detail) =>
    AssetClientException(
      AssetClientErrorCode.network,
      status: status,
      detail: detail,
    );

/// Whether [r] is a character a log line or a label must not carry as is:
/// C0 and C1 controls; the format characters — directional marks,
/// embeddings, overrides and isolates, zero-width characters,
/// prefixed-number formats, the tag block; the blanks that render as
/// nothing — Hangul fillers, variation selectors, the grapheme joiner, the
/// blank Braille cell; the line and paragraph separators and lone
/// surrogates. A list, not the Unicode `Cf` category, which Dart does not
/// expose: extend it when Unicode adds one.
bool isUnsafeRune(int r) =>
    r < 0x20 ||
    (r >= 0x7f && r < 0xa0) ||
    r == 0xad ||
    r == 0x34f ||
    (r >= 0x600 && r <= 0x605) ||
    r == 0x61c ||
    r == 0x6dd ||
    r == 0x70f ||
    (r >= 0x890 && r <= 0x891) ||
    r == 0x8e2 ||
    r == 0x115f ||
    r == 0x1160 ||
    r == 0x180e ||
    (r >= 0x200b && r <= 0x200f) ||
    (r >= 0x2028 && r <= 0x202e) ||
    (r >= 0x2060 && r <= 0x206f) ||
    r == 0x2800 ||
    r == 0x3164 ||
    (r >= 0xd800 && r <= 0xdfff) ||
    (r >= 0xfe00 && r <= 0xfe0f) ||
    r == 0xfeff ||
    r == 0xffa0 ||
    (r >= 0xfff9 && r <= 0xfffb) ||
    r == 0x110bd ||
    r == 0x110cd ||
    (r >= 0x13430 && r <= 0x1343f) ||
    (r >= 0x1bca0 && r <= 0x1bca3) ||
    (r >= 0x1d173 && r <= 0x1d17a) ||
    (r >= 0xe0000 && r <= 0xe007f) ||
    (r >= 0xe0100 && r <= 0xe01ef);

/// A path as it may appear in a log line: at most 64 characters, every
/// [isUnsafeRune] replaced with `?`, because a manifest — and so the CDN —
/// chose it.
String loggablePath(String path) {
  final out = StringBuffer();
  var count = 0;
  for (final r in path.runes) {
    if (count++ == 64) {
      out.write('…');
      break;
    }
    out.writeCharCode(isUnsafeRune(r) ? 0x3f : r);
  }
  return out.toString();
}

/// Reads a body in exact-sized pieces without holding more of it than one
/// piece: a download of 256 MiB keeps one 64 KiB segment in memory. Every
/// piece must arrive within the idle timeout, and a client closed meanwhile
/// ends the read with a [StateError].
final class BodyReader {
  BodyReader._(this._stream, this._status, this._idle, this._isClosed)
    : _iterator = StreamIterator<List<int>>(_stream);

  final Stream<List<int>> _stream;
  final StreamIterator<List<int>> _iterator;
  final Duration _idle;
  final bool Function() _isClosed;
  bool _started = false;
  final int _status;
  Uint8List? _pending;
  bool _finished = false;

  Future<Uint8List?> _pull() async {
    if (_isClosed()) {
      await cancel();
      throw StateError('asset client is closed');
    }
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      return pending;
    }
    if (_finished) return null;
    _started = true;
    try {
      while (await _iterator.moveNext().timeout(_idle)) {
        final chunk = _iterator.current;
        if (chunk.isNotEmpty) {
          // A piece that arrives after a close is not handed on.
          if (_isClosed()) {
            await cancel();
            throw StateError('asset client is closed');
          }
          return chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        }
      }
    } on TimeoutException {
      await cancel();
      if (_isClosed()) throw StateError('asset client is closed');
      throw networkError(_status, 'the body stalled');
    } on Object {
      // Nothing of the transport's error crosses: it may name the URL. A
      // client closed under the read is the caller's doing, not the host's.
      _finished = true;
      if (_isClosed()) throw StateError('asset client is closed');
      throw networkError(_status, 'the body failed mid-transfer');
    }
    _finished = true;
    if (_isClosed()) throw StateError('asset client is closed');
    return null;
  }

  /// Exactly [n] bytes; a body that ends first is `network`.
  Future<Uint8List> readExactly(int n) async {
    final out = Uint8List(n);
    var size = 0;
    while (size < n) {
      final chunk = await _pull();
      if (chunk == null) throw networkError(_status, 'the body ended early');
      final take = chunk.length < n - size ? chunk.length : n - size;
      out.setRange(size, size + take, chunk);
      if (take < chunk.length) _pending = Uint8List.sublistView(chunk, take);
      size += take;
    }
    return out;
  }

  /// The next piece as the transport delivered it; `null` at the end.
  Future<Uint8List?> next() => _pull();

  /// Everything that is left, refused once it passes [max] bytes — by
  /// [overflow], or as `http` because no asset is larger.
  Future<Uint8List> rest(
    int max, [
    AssetClientException Function(int status) overflow = tooLarge,
  ]) async {
    final builder = BytesBuilder(copy: false);
    for (var chunk = await _pull(); chunk != null; chunk = await _pull()) {
      builder.add(chunk);
      if (builder.length > max) {
        await cancel();
        throw overflow(_status);
      }
    }
    return builder.takeBytes();
  }

  /// Stops the transfer and releases the connection; safe to call twice.
  Future<void> cancel() async {
    if (_finished) return;
    _finished = true;
    _pending = null;
    try {
      // A StreamIterator that never moved has not subscribed, and cancelling
      // it would leave the response unlistened — holding its connection.
      if (_started) {
        await _iterator.cancel();
      } else {
        await _stream.listen(null).cancel();
      }
    } on Object {
      // The transfer is being abandoned either way.
    }
  }
}

/// One answer the client may use: `200`, `206` or `416`.
final class Answer {
  Answer._(
    this.status,
    this.etag,
    this.range,
    this.unsatisfiedTotal,
    this.length,
    this.encoded,
    this.body,
  );

  /// The status.
  final int status;

  /// A strong or weak ETag as sent, when the host exposed one.
  final String? etag;

  /// `Content-Range`, when the host sent one and the caller may read it.
  final ContentRange? range;

  /// The length a 416 states (`bytes */L`).
  final int? unsatisfiedTotal;

  /// `Content-Length`, when present and numeric.
  final int? length;

  /// Whether the host said the body is content-encoded.
  final bool encoded;

  /// The body.
  final BodyReader body;
}

/// What to ask for.
final class RequestSpec {
  /// Creates a spec. [to] is inclusive; omitted means open-ended.
  const RequestSpec(
    this.method,
    this.kind, {
    this.from,
    this.to,
    this.ifRange,
    this.noCache = false,
  });

  /// `GET` or `HEAD`.
  final String method;

  /// What it is for, for the log line.
  final RequestKind kind;

  /// First byte of the `Range`, or `null` for no `Range`.
  final int? from;

  /// Last byte of the `Range`, inclusive; `null` for open-ended.
  final int? to;

  /// A strong ETag for `If-Range`.
  final String? ifRange;

  /// Send `Cache-Control: no-cache` (never in CORS-safe mode).
  final bool noCache;
}

/// The single request choke point: one header assembly, one log line per
/// request. Logged are the request kind, the path, the status and the range
/// — never the key, a byte of the body, a URL or a header value.
final class Requester {
  /// Creates a requester over [client]. [timeout] bounds the response
  /// headers, [idle] each wait for the next piece of a body.
  Requester(
    this._client,
    this._logger,
    this._timeout,
    this._idle,
    this._isClosed,
  );

  final http.Client _client;
  final Logger _logger;
  final Duration _timeout;
  final Duration _idle;
  final bool Function() _isClosed;

  /// Sends one request and returns a usable answer; `403`/`404` is
  /// `not_found`, any other refusal `http`, no answer `network`.
  Future<Answer> send(String url, String path, RequestSpec spec) async {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      spec.method,
      Uri.parse(url),
      abortTrigger: abort.future,
    );
    final from = spec.from;
    String? range;
    if (from != null) {
      range = 'bytes=$from-${spec.to ?? ''}';
      request.headers['range'] = range;
    }
    final ifRange = spec.ifRange;
    if (ifRange != null) request.headers['if-range'] = ifRange;
    if (spec.noCache) request.headers['cache-control'] = 'no-cache';
    // The deadline covers the response headers; a body is read at the
    // caller's pace, each piece within the idle timeout.
    http.StreamedResponse response;
    final sending = Future<http.StreamedResponse>.sync(
      () => _client.send(request),
    );
    try {
      // The abort frees the connection with a client that honours it; the
      // timeout bounds the wait with any client.
      response = await sending.timeout(_timeout);
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      // A client that ignored the abort may still answer: release that
      // answer's connection when it comes.
      sending.then((answer) => answer.stream.listen(null).cancel()).ignore();
      if (_isClosed()) throw StateError('asset client is closed');
      _logger.warn('asset request failed', <String, Object?>{
        'kind': spec.kind.name,
        'path': loggablePath(path),
      });
      throw const AssetClientException(
        AssetClientErrorCode.network,
        detail: 'no response in time',
      );
    } on Object {
      // Nothing of the transport's error crosses: it may name the URL.
      if (_isClosed()) throw StateError('asset client is closed');
      _logger.warn('asset request failed', <String, Object?>{
        'kind': spec.kind.name,
        'path': loggablePath(path),
      });
      throw const AssetClientException(AssetClientErrorCode.network);
    }
    final status = response.statusCode;
    _logger.debug('asset request', <String, Object?>{
      'kind': spec.kind.name,
      'path': loggablePath(path),
      'status': status,
      'range': ?range,
    });
    final body = BodyReader._(response.stream, status, _idle, _isClosed);
    if (_isClosed()) {
      await body.cancel();
      throw StateError('asset client is closed');
    }
    if (status == 403 || status == 404) {
      await body.cancel();
      throw AssetClientException(AssetClientErrorCode.notFound, status: status);
    }
    if (status != 200 && status != 206 && status != 416) {
      await body.cancel();
      throw AssetClientException(AssetClientErrorCode.http, status: status);
    }
    final headers = response.headers;
    final encoding = headers['content-encoding'];
    return Answer._(
      status,
      headers['etag'],
      parseContentRange(headers['content-range']),
      _parseUnsatisfied(headers['content-range']),
      _parseLength(headers['content-length']) ?? response.contentLength,
      encoding != null && encoding.trim().toLowerCase() != 'identity',
      body,
    );
  }
}
