import 'dart:async';

import 'package:fake_async/fake_async.dart';
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

void main() {
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
