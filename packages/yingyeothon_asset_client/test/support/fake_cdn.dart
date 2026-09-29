import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_asset_client/yingyeothon_asset_client.dart';

/// One request as it went on the wire.
final class Recorded {
  Recorded(this.url, this.method, this.headers);
  final String url;
  final String method;
  final Map<String, String> headers;

  String? get range => headers['range'];
  String? get ifRange => headers['if-range'];

  @override
  String toString() =>
      '$method ${range ?? '-'}${ifRange == null ? '' : ' if-range'}';
}

/// A scripted CDN: objects by URL, `Range`/`If-Range`/`HEAD` as CloudFront
/// answers them, a missing object as 403, and every request recorded so a
/// test asserts exactly what went on the wire.
final class FakeCdn extends http.BaseClient {
  FakeCdn({
    this.ignoreRange = false,
    this.ignoreIfRange = false,
    this.crossOrigin = false,
    this.noEtag = false,
    this.chunkSize = 7000,
    this.beforeAnswer,
  });

  /// Answer every GET with the whole object, as a host without Range does.
  final bool ignoreRange;

  /// Serve the range even when `If-Range` names another ETag.
  final bool ignoreIfRange;

  /// What a cross-origin script sees: only `ETag` and `Content-Length`.
  final bool crossOrigin;

  /// Send no `ETag` at all.
  final bool noEtag;

  /// How the body is cut into stream chunks.
  final int chunkSize;

  /// Runs before each answer, with the request's index: mutate the CDN here.
  final void Function(int index, Recorded request)? beforeAnswer;

  final Map<String, ({Uint8List bytes, String etag})> _objects = {};
  final List<Recorded> requests = <Recorded>[];
  int _generation = 0;
  int _openBodies = 0;
  bool _refuseRange = false;

  /// Answers with a status of its own for every request while set.
  int? forceStatus;

  /// Throws from `send` while set, as a network failure does.
  Object? failWith;

  /// Bodies handed out and neither read to the end nor cancelled.
  int get openBodies => _openBodies;

  /// Serves [bytes] at [url]; returns the new ETag.
  String serve(String url, Uint8List bytes) {
    _generation++;
    final etag = '"etag-$_generation"';
    _objects[url] = (bytes: bytes, etag: etag);
    return etag;
  }

  void remove(String url) => _objects.remove(url);

  /// A request carrying `Range` then throws, as a refused preflight does.
  void refuseRange([bool on = true]) => _refuseRange = on;

  /// One chunk per pump, and only while the listener is not paused: a body is
  /// open from its answer until it was read to the end or cancelled, so a
  /// body the client abandoned without cancelling stays counted.
  Stream<List<int>> _stream(Uint8List bytes) {
    _openBodies++;
    var open = true;
    void release() {
      if (open) _openBodies--;
      open = false;
    }

    var at = 0;
    late final StreamController<List<int>> controller;
    void pump() {
      if (!open || controller.isPaused || !controller.hasListener) return;
      if (at >= bytes.length) {
        release();
        unawaited(controller.close());
        return;
      }
      final end = at + chunkSize < bytes.length ? at + chunkSize : bytes.length;
      controller.add(Uint8List.fromList(Uint8List.sublistView(bytes, at, end)));
      at = end;
      scheduleMicrotask(pump);
    }

    controller = StreamController<List<int>>(
      onListen: pump,
      onResume: pump,
      onCancel: release,
    );
    return controller.stream;
  }

  http.StreamedResponse _answer(
    int status,
    Map<String, String> headers,
    Uint8List? bytes,
  ) {
    final visible = Map<String, String>.of(headers);
    if (crossOrigin) {
      visible.removeWhere((k, _) => k != 'etag' && k != 'content-length');
    }
    if (noEtag) visible.remove('etag');
    return http.StreamedResponse(
      bytes == null ? const Stream<List<int>>.empty() : _stream(bytes),
      status,
      headers: visible,
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final recorded = Recorded(
      request.url.toString(),
      request.method,
      Map<String, String>.of(request.headers),
    );
    requests.add(recorded);
    beforeAnswer?.call(requests.length - 1, recorded);
    final fail = failWith;
    if (fail != null) throw fail;
    if (_refuseRange && recorded.range != null) {
      throw http.ClientException('Failed to fetch', request.url);
    }
    final forced = forceStatus;
    if (forced != null) return _answer(forced, const {}, Uint8List(0));
    final object = _objects[recorded.url];
    if (object == null) return _answer(403, const {}, Uint8List(0));
    final bytes = object.bytes;
    final size = bytes.length;
    final base = {
      'etag': object.etag,
      'content-type': 'application/octet-stream',
    };
    if (request.method == 'HEAD') {
      return _answer(200, {...base, 'content-length': '$size'}, null);
    }
    final range = recorded.range;
    final ifRange = recorded.ifRange;
    final honour =
        range != null &&
        !ignoreRange &&
        (ifRange == null || ifRange == object.etag || ignoreIfRange);
    if (!honour) {
      return _answer(200, {...base, 'content-length': '$size'}, bytes);
    }
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (match == null) throw StateError('fake cdn: bad range');
    final from = int.parse(match.group(1)!);
    final asked = match.group(2)!;
    final to = asked.isEmpty
        ? size - 1
        : (int.parse(asked) < size - 1 ? int.parse(asked) : size - 1);
    if (from >= size) {
      return _answer(416, {
        ...base,
        'content-range': 'bytes */$size',
      }, Uint8List(0));
    }
    final body = Uint8List.fromList(Uint8List.sublistView(bytes, from, to + 1));
    return _answer(206, {
      ...base,
      'content-length': '${body.length}',
      'content-range': 'bytes $from-$to/$size',
    }, body);
  }
}

/// A capturing sink: what `download` wrote, in order, and every reset.
final class MemorySink implements AssetSink {
  final BytesBuilder _bytes = BytesBuilder();
  final List<String> events = <String>[];

  /// Pre-fills the sink as an earlier, interrupted download left it.
  void seed(Uint8List bytes) => _bytes.add(bytes);

  Uint8List get bytes => _bytes.toBytes();

  @override
  void write(Uint8List chunk) {
    _bytes.add(Uint8List.fromList(chunk));
    events.add('write:${chunk.length}');
  }

  @override
  void reset() {
    _bytes.clear();
    events.add('reset');
  }
}
