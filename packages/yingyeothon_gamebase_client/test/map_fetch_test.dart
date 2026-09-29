import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import 'support/harness.dart';

final class ScriptedFetcher implements MapHttpFetcher {
  final List<Uri> calls = <Uri>[];
  final List<Completer<HttpFetchResult>> pending =
      <Completer<HttpFetchResult>>[];
  Object? throwSync;

  @override
  Future<HttpFetchResult> get(Uri url) {
    calls.add(url);
    final sync = throwSync;
    if (sync != null) throw sync;
    final c = Completer<HttpFetchResult>();
    pending.add(c);
    return c.future;
  }

  void answer(int status, String body) =>
      pending.removeAt(0).complete(HttpFetchResult(status: status, body: body));

  void fail(Object error) => pending.removeAt(0).completeError(error);
}

/// Counts `close()`; never answers.
final class _ClosingClient extends http.BaseClient {
  int closes = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;

  @override
  void close() => closes++;
}

void main() {
  test('map() after close() is refused; an injected fetcher stays open', () {
    fakeAsync((async) {
      final client = _ClosingClient();
      final h = LobbyHarness(async, httpFetcher: HttpMapFetcher(client: client))
        ..connect();
      h.openAndHello();
      Object? inFlight;
      h.client.map().catchError((Object e) => inFlight = e);
      unawaited(h.client.close());
      async.flushMicrotasks();
      expect(
        () => h.client.map(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'map() after close()',
          ),
        ),
      );
      expect(client.closes, 0, reason: 'the caller owns what it passed');
      async.elapse(const Duration(seconds: 31));
      // The injected client was not closed, so the fetch ran to its deadline.
      expect((inFlight! as MapFetchException).reason, 'timeout');
    });
  });

  test('map() needs hello first', () {
    fakeAsync((async) {
      final h = LobbyHarness(async);
      expect(() => h.client.map(), throwsStateError);
    });
  });

  test('caches per URL, shares concurrent calls, keeps across reconnects', () {
    fakeAsync((async) {
      final fetcher = ScriptedFetcher();
      final h = LobbyHarness(async, httpFetcher: fetcher)..connect();
      h.openAndHello();
      final results = <Object?>[];
      h.client.map().then(results.add);
      h.client.map().then(results.add);
      expect(fetcher.calls, hasLength(1));
      expect(fetcher.calls.single.toString(), 'https://d.example/map.json');
      fetcher.answer(200, '{"w":3}');
      async.flushMicrotasks();
      expect(results, [
        <String, Object?>{'w': 3},
        <String, Object?>{'w': 3},
      ]);
      h.socket.serverClose(4002);
      h.elapse(500);
      h.openAndHello();
      h.client.map().then(results.add);
      async.flushMicrotasks();
      expect(fetcher.calls, hasLength(1));
      expect(results, hasLength(3));
      expect(
        h.log.lines.join('\n'),
        isNot(contains('d.example')),
        reason: 'the URL is logged by length only',
      );
      // A stop the caller did not ask for still serves the cached map.
      h.socket.serverClose(4000);
      expect(h.client.state, GatewayClientState.closed);
      h.client.map().then(results.add);
      async.flushMicrotasks();
      expect(results, hasLength(4));
    });
  });

  test('a failure is evicted so the next call retries', () {
    fakeAsync((async) {
      final fetcher = ScriptedFetcher();
      final h = LobbyHarness(async, httpFetcher: fetcher)..connect();
      h.openAndHello();
      Object? error;
      h.client.map().catchError((Object e) {
        error = e;
        return null;
      });
      fetcher.answer(500, 'nope');
      async.flushMicrotasks();
      expect(error, isA<MapFetchException>());
      expect((error! as MapFetchException).status, 500);
      Object? body;
      h.client.map().then((b) => body = b);
      expect(fetcher.calls, hasLength(2));
      fetcher.answer(200, 'not json');
      async.flushMicrotasks();
      expect(body, 'not json');
    });
  });

  test('a synchronously failing fetcher still evicts the right entry', () {
    fakeAsync((async) {
      final fetcher = ScriptedFetcher()..throwSync = StateError('boom');
      final h = LobbyHarness(async, httpFetcher: fetcher)..connect();
      h.openAndHello();
      Object? error;
      h.client.map().catchError((Object e) {
        error = e;
        return null;
      });
      async.flushMicrotasks();
      expect(error, isStateError);
      fetcher.throwSync = null;
      h.client.map();
      expect(fetcher.calls, hasLength(2));
    });
  });

  test('a mapUrl that is not an absolute http(s) URL is refused as badUrl', () {
    fakeAsync((async) {
      final fetcher = ScriptedFetcher();
      final h = LobbyHarness(async, httpFetcher: fetcher)..connect();
      h.openAndHello(hello: helloFrame(mapUrl: 'file:///etc/passwd'));
      Object? error;
      h.client.map().catchError((Object e) {
        error = e;
        return null;
      });
      async.flushMicrotasks();
      expect((error! as MapFetchException).reason, 'badUrl');
      expect(fetcher.calls, isEmpty, reason: 'never reached the fetcher');
      expect(error.toString(), isNot(contains('passwd')));
    });
  });

  test('a body over the big cap is a failure, not text', () {
    fakeAsync((async) {
      final fetcher = ScriptedFetcher();
      final h = LobbyHarness(async, httpFetcher: fetcher)..connect();
      h.openAndHello();
      Object? error;
      h.client.map().catchError((Object e) {
        error = e;
        return null;
      });
      fetcher.answer(200, 'x' * (64 * 1024 * 1024 + 1));
      async.flushMicrotasks();
      expect(error, isA<MapFetchException>());
      expect((error! as MapFetchException).reason, 'tooLarge');
    });
  });
}
