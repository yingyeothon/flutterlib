import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// The fixture token: three dot-separated words that look like a JWT to a
/// human and are not one. The "never logs the token" tests search for it.
const String fixtureToken = 'eyJ.secret-token.sig';

/// A scripted HTTP client. Every request is recorded; each answer comes from
/// a queue and may be a response, an exception to throw, or a stall that
/// never answers (to drive the timeout).
final class FakeHttp extends http.BaseClient {
  final List<http.Request> requests = <http.Request>[];
  final List<Object> _answers = <Object>[];
  bool closed = false;

  /// Queues a response.
  void answer(
    int status, [
    String body = '',
    Map<String, String> headers = const <String, String>{},
  ]) => _answers.add(_Response(status, body, headers, true));

  /// Queues a response without a `Content-Length`, delivered in 64 KiB
  /// chunks.
  void answerChunked(int status, String body) =>
      _answers.add(_Response(status, body, const <String, String>{}, false));

  /// Queues an exception `send` throws.
  void fail(Object error) => _answers.add(error);

  /// Queues a response whose headers arrive and whose body never ends.
  void stallBody(int status) => _answers.add(_Stall(status));

  /// Queues a `send` that never completes.
  void stallHeaders() => _answers.add(const _Stall(null));

  /// Queues a response whose body delivers one byte every [every], forever.
  void dripBody(int status, Duration every) =>
      _answers.add(_Drip(status, every));

  /// The one request made so far, asserting there was exactly one.
  http.Request get single {
    expect(requests, hasLength(1));
    return requests.single;
  }

  /// Whether an `abortTrigger` of a recorded request has fired.
  final List<bool> aborted = <bool>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    if (request is http.AbortableRequest) {
      final slot = aborted.length;
      aborted.add(false);
      unawaited(request.abortTrigger?.then((_) => aborted[slot] = true));
    }
    if (_answers.isEmpty) fail('no scripted answer for $request');
    final next = _answers.removeAt(0);
    if (next is _Response) {
      final bytes = utf8.encode(next.body);
      if (!next.declareLength) {
        return http.StreamedResponse(
          Stream<List<int>>.fromIterable(<List<int>>[
            for (var i = 0; i < bytes.length; i += 1 << 16)
              bytes.sublist(i, (i + (1 << 16)).clamp(0, bytes.length)),
          ]),
          next.status,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        next.status,
        headers: next.headers,
        contentLength: bytes.length,
      );
    }
    if (next is _Drip) {
      return http.StreamedResponse(
        Stream<List<int>>.periodic(next.every, (_) => <int>[120]),
        next.status,
      );
    }
    if (next is _Stall) {
      if (next.status == null) return Completer<http.StreamedResponse>().future;
      return http.StreamedResponse(
        StreamController<List<int>>().stream,
        next.status!,
      );
    }
    throw next;
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

final class _Response {
  const _Response(this.status, this.body, this.headers, this.declareLength);
  final int status;
  final String body;
  final Map<String, String> headers;
  final bool declareLength;
}

final class _Drip {
  const _Drip(this.status, this.every);
  final int status;
  final Duration every;
}

final class _Stall {
  const _Stall(this.status);
  final int? status;
}
