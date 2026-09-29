import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

/// Answers each request with what [respond] builds; a `null` never answers.
final class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.respond);

  final FutureOr<http.StreamedResponse>? Function(http.BaseRequest) respond;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  int closes = 0;

  @override
  void close() => closes++;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final answer = respond(request);
    if (answer == null) return Completer<http.StreamedResponse>().future;
    return answer;
  }
}

/// A `send` that is not `async`: it throws before any future exists.
final class _SyncThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw http.ClientException('refused', request.url);
}

http.StreamedResponse _answer(
  int status,
  Stream<List<int>> body, {
  int? contentLength,
}) => http.StreamedResponse(body, status, contentLength: contentLength);

final Uri _url = Uri.parse('https://cdn.example/map.json');

void main() {
  test('a settled fetch leaves no timer behind', () {
    fakeAsync((async) {
      final client = _ScriptedClient(
        (_) => _answer(200, Stream.value(utf8.encode('{"a":1}'))),
      );
      HttpFetchResult? result;
      HttpMapFetcher(client: client).get(_url).then((r) => result = r);
      async.flushMicrotasks();
      expect(result?.status, 200);
      expect(result?.body, '{"a":1}');
      // The 30 s deadline was cancelled, not left to run out.
      expect(async.pendingTimers, isEmpty);
      final request = client.requests.single;
      expect(request.method, 'GET');
      expect(request.headers, isEmpty, reason: 'no credentials to a CDN');
    });
  });

  test('a failed fetch leaves no timer behind either', () {
    fakeAsync((async) {
      final client = _ScriptedClient(
        (_) => throw http.ClientException('boom https://cdn.example', _url),
      );
      Object? error;
      HttpMapFetcher(client: client).get(_url).catchError((Object e) {
        error = e;
        return const HttpFetchResult(status: 0, body: '');
      });
      async.flushMicrotasks();
      expect(error, isA<MapFetchException>());
      expect((error! as MapFetchException).reason, 'network');
      expect(error.toString(), 'MapFetchException(network, status 0)');
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('no headers within the timeout is a timeout; one tick less is not', () {
    fakeAsync((async) {
      final client = _ScriptedClient((_) => null);
      var aborted = false;
      Object? error;
      HttpMapFetcher(
        client: client,
        timeout: const Duration(seconds: 2),
      ).get(_url).catchError((Object e) {
        error = e;
        return const HttpFetchResult(status: 0, body: '');
      });
      final request = client.requests.single as http.Abortable;
      request.abortTrigger!.then((_) => aborted = true);
      async.elapse(const Duration(milliseconds: 1999));
      expect(error, isNull);
      expect(aborted, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect((error! as MapFetchException).reason, 'timeout');
      expect((error! as MapFetchException).status, 0);
      async.flushMicrotasks();
      expect(aborted, isTrue, reason: 'the request is aborted at the deadline');
    });
  });

  test('headers that arrive after the deadline are drained, not held', () {
    fakeAsync((async) {
      final late = Completer<http.StreamedResponse>();
      var cancelled = false;
      final body = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final client = _ScriptedClient((_) => late.future);
      Object? error;
      HttpMapFetcher(
        client: client,
        timeout: const Duration(seconds: 2),
      ).get(_url).catchError((Object e) {
        error = e;
        return const HttpFetchResult(status: 0, body: '');
      });
      async.elapse(const Duration(seconds: 2));
      expect((error! as MapFetchException).reason, 'timeout');
      expect(body.hasListener, isFalse);
      late.complete(_answer(200, body.stream));
      async.flushMicrotasks();
      expect(cancelled, isTrue);
      unawaited(body.close());
    });
  });

  test('a body that drips past the deadline is a timeout with the status', () {
    fakeAsync((async) {
      final body = StreamController<List<int>>();
      final client = _ScriptedClient((_) => _answer(200, body.stream));
      Object? error;
      HttpMapFetcher(
        client: client,
        timeout: const Duration(seconds: 2),
      ).get(_url).catchError((Object e) {
        error = e;
        return const HttpFetchResult(status: 0, body: '');
      });
      for (var i = 0; i < 4; i++) {
        body.add(<int>[0x20]);
        async.elapse(const Duration(milliseconds: 600));
      }
      expect((error! as MapFetchException).reason, 'timeout');
      expect((error! as MapFetchException).status, 200);
      expect(async.pendingTimers, isEmpty);
      unawaited(body.close());
    });
  });

  test('any other exception from the client is network, quoting nothing', () {
    fakeAsync((async) {
      final client = _ScriptedClient(
        (_) => throw const FormatException('tls: cdn.example refused'),
      );
      Object? error;
      HttpMapFetcher(client: client).get(_url).catchError((Object e) {
        error = e;
        return const HttpFetchResult(status: 0, body: '');
      });
      async.flushMicrotasks();
      expect(error.toString(), 'MapFetchException(network, status 0)');
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a client that throws synchronously is still network', () {
    fakeAsync((async) {
      Object? error;
      HttpMapFetcher(client: _SyncThrowingClient())
          .get(_url)
          .catchError((Object e) {
            error = e;
            return const HttpFetchResult(status: 0, body: '');
          });
      async.flushMicrotasks();
      expect(error.toString(), 'MapFetchException(network, status 0)');
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('close() leaves an injected client open', () {
    final injected = _ScriptedClient((_) => null);
    HttpMapFetcher(client: injected)
      ..close()
      ..close();
    expect(injected.closes, 0);
  });

  test(
    'close() releases the client it created: nothing reaches the host',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) {
        requests++;
        request.response
          ..write('{}')
          ..close();
      });
      final url = Uri.parse('http://127.0.0.1:${server.port}/map.json');
      // Positive control: the same fetcher shape reaches the host when open.
      final open = HttpMapFetcher();
      addTearDown(open.close);
      expect((await open.get(url)).body, '{}');
      expect(requests, 1);
      final closed = HttpMapFetcher()
        ..close()
        ..close();
      await expectLater(
        closed.get(url),
        throwsA(
          isA<MapFetchException>().having((e) => e.reason, 'reason', 'network'),
        ),
      );
      expect(requests, 1);
    },
    tags: <String>['integration'],
  );

  test('the byte cap holds on the declared length and while streaming', () {
    fakeAsync((async) {
      for (final (declared, chunks) in <(int?, List<List<int>>)>[
        (5, <List<int>>[]),
        (
          null,
          <List<int>>[
            <int>[1, 2, 3],
            <int>[4, 5],
          ],
        ),
      ]) {
        final client = _ScriptedClient(
          (_) => _answer(
            200,
            Stream.fromIterable(chunks),
            contentLength: declared,
          ),
        );
        Object? error;
        HttpMapFetcher(client: client, maxBytes: 4).get(_url).catchError((
          Object e,
        ) {
          error = e;
          return const HttpFetchResult(status: 0, body: '');
        });
        async.flushMicrotasks();
        expect((error! as MapFetchException).reason, 'tooLarge');
        expect(async.pendingTimers, isEmpty);
      }
      // Exactly at the cap passes.
      HttpFetchResult? result;
      HttpMapFetcher(
        client: _ScriptedClient(
          (_) => _answer(200, Stream.value(<int>[0x31, 0x32, 0x33, 0x34])),
        ),
        maxBytes: 4,
      ).get(_url).then((r) => result = r);
      async.flushMicrotasks();
      expect(result?.body, '1234');
    });
  });
}
