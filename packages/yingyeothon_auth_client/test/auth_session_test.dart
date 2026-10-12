import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';

String jwt(String user, int expiry) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': user, 'exp': expiry}))).replaceAll('=', '')}.fixture';

final class Storage implements AuthTokenStorage {
  String? value;
  bool fail = false;
  @override
  Future<String?> load() async {
    if (fail) throw StateError('secret');
    return value;
  }

  @override
  Future<void> store(String token) async {
    if (fail) throw StateError('secret');
    value = token;
  }

  @override
  Future<void> clear() async {
    if (fail) throw StateError('secret');
    value = null;
  }
}

void main() {
  test(
    'monotonic midpoint ignores wall time and warning fires exactly once',
    () {
      fakeAsync((async) {
        final session = AuthSession(
          AuthSessionOptions(
            fetchServerTime: () =>
                Future.value(DateTime.fromMillisecondsSinceEpoch(1000000)),
            monotonicMilliseconds: () => async.elapsed.inMilliseconds,
          ),
        );
        final trace = <String>[];
        session.changed.listen(
          (identity) => trace.add(
            identity == null ? 'change:out' : 'change:${identity.userId}',
          ),
        );
        session.expiring.listen((_) => trace.add('expiring'));
        session.signedOut.listen((_) => trace.add('out'));
        unawaited(session.fromToken(jwt('a', 2000)));
        async.flushMicrotasks();
        expect(session.token, isNotNull);
        expect(session.userId, 'a');
        expect(session.expiresAt, 2000);
        expect(session.now(), 1000000);
        async.elapse(const Duration(seconds: 399));
        expect(trace, ['change:a']);
        async.elapse(const Duration(seconds: 1));
        expect(trace, ['change:a', 'expiring']);
        async.elapse(const Duration(seconds: 600));
        async.flushMicrotasks();
        expect(trace, ['change:a', 'expiring', 'change:out', 'out']);
        expect(session.token, null);
        expect(async.pendingTimers, isEmpty);
        unawaited(session.close());
        async.flushMicrotasks();
      });
    },
  );
  test('request midpoint and long deadlines are bounded and canceled', () {
    fakeAsync((async) {
      final answer = Completer<DateTime>();
      final session = AuthSession(
        AuthSessionOptions(
          fetchServerTime: () => answer.future,
          monotonicMilliseconds: () => async.elapsed.inMilliseconds,
        ),
      );
      unawaited(session.fromToken(jwt('a', 10000000)));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      answer.complete(DateTime.fromMillisecondsSinceEpoch(1000));
      async.flushMicrotasks();
      expect(session.now(), 1050);
      async.elapse(const Duration(days: 1));
      expect(session.userId, 'a');
      unawaited(session.close());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      expect(session.now, throwsA(isA<AuthSessionException>()));
    });
  });
  test(
    'offline adoption retains identity but refuses wall-clock fallback',
    () async {
      final session = AuthSession(
        AuthSessionOptions(
          fetchServerTime: () => Future.error(StateError('secret')),
        ),
      );
      addTearDown(session.close);
      final token = await session.fromToken(jwt('a', 2000));
      expect(token.userId, 'a');
      expect(
        session.now,
        throwsA(
          isA<AuthSessionException>().having(
            (e) => e.code,
            'code',
            'unavailable',
          ),
        ),
      );
      await expectLater(
        session.synchronize(),
        throwsA(isA<AuthSessionException>()),
      );
    },
  );
  test(
    'storage restoration, explicit signout and login share identity lifecycle',
    () async {
      final storage = Storage();
      final token = jwt('a', 2000);
      final session = AuthSession(
        AuthSessionOptions(
          fetchServerTime: () =>
              Future.value(DateTime.fromMillisecondsSinceEpoch(1000000)),
          storage: storage,
          signIn: () =>
              Future.value(ChannelToken(jwt: token, userId: 'a', exp: 2000)),
        ),
      );
      addTearDown(session.close);
      expect(await session.restore(), null);
      await session.signIn();
      expect(storage.value, token);
      await session.restore();
      final outs = <void>[];
      final sub = session.signedOut.listen(outs.add);
      await session.signOut();
      await session.signOut();
      expect(outs, hasLength(1));
      expect(storage.value, null);
      await sub.cancel();
    },
  );
  test(
    'malformed claims and platform storage errors never quote inputs',
    () async {
      final storage = Storage();
      final session = AuthSession(
        AuthSessionOptions(
          fetchServerTime: () =>
              Future.value(DateTime.fromMillisecondsSinceEpoch(0)),
          storage: storage,
        ),
      );
      addTearDown(session.close);
      for (final token in [
        'bad',
        'a' * 8193,
        'bad\n',
        jwt('', 100),
        jwt('a', 100).replaceFirst('e30.', 'e30.%%%%'),
      ]) {
        await expectLater(session.fromToken(token), throwsArgumentError);
      }
      await expectLater(session.signIn(), throwsA(isA<AuthSessionException>()));
      storage.fail = true;
      await expectLater(
        session.restore(),
        throwsA(isA<AuthSessionException>()),
      );
      await expectLater(
        session.fromToken(jwt('a', 2000)),
        throwsA(isA<AuthSessionException>()),
      );
      await expectLater(
        session.signOut(),
        throwsA(isA<AuthSessionException>()),
      );
    },
  );
  test(
    'identity changes discard stale synchronization and stale login',
    () async {
      final times = <Completer<DateTime>>[];
      final login = Completer<ChannelToken>();
      final session = AuthSession(
        AuthSessionOptions(
          fetchServerTime: () {
            final time = Completer<DateTime>();
            times.add(time);
            return time.future;
          },
          signIn: () => login.future,
          monotonicMilliseconds: () => 0,
        ),
      );
      addTearDown(session.close);
      final a = session.fromToken(jwt('a', 2000));
      final failed = expectLater(a, throwsA(isA<AuthSessionException>()));
      final b = session.fromToken(jwt('b', 3000));
      expect(times, hasLength(2));
      times[0].complete(DateTime.fromMillisecondsSinceEpoch(100));
      times[1].complete(DateTime.fromMillisecondsSinceEpoch(200));
      await failed;
      await b;
      expect(session.userId, 'b');
      expect(session.now(), 200);
      final signing = session.signIn();
      final canceled = expectLater(
        signing,
        throwsA(
          isA<AuthSessionException>().having(
            (e) => e.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await session.signOut();
      login.complete(ChannelToken(jwt: jwt('a', 2000), userId: 'a', exp: 2000));
      await canceled;
    },
  );
  test('closing retains secure storage but cancels identity work', () async {
    final storage = Storage();
    final session = AuthSession(
      AuthSessionOptions(
        fetchServerTime: () =>
            Future.value(DateTime.fromMillisecondsSinceEpoch(0)),
        storage: storage,
      ),
    );
    await session.fromToken(jwt('a', 1000));
    await session.close();
    await session.close();
    expect(storage.value, isNotNull);
    await expectLater(
      session.fromToken(jwt('b', 1000)),
      throwsA(isA<AuthSessionException>()),
    );
  });
  test(
    'failed token persistence rolls back an announced identity and its timers',
    () {
      fakeAsync((async) {
        final storage = Storage();
        final session = AuthSession(
          AuthSessionOptions(
            storage: storage,
            fetchServerTime: () =>
                Future.value(DateTime.fromMillisecondsSinceEpoch(1000000)),
            monotonicMilliseconds: () => async.elapsed.inMilliseconds,
          ),
        );
        unawaited(session.fromToken(jwt('a', 2000)));
        async.flushMicrotasks();
        storage.fail = true;
        Object? error;
        unawaited(
          session.fromToken(jwt('b', 1001)).catchError((Object e) {
            error = e;
            return ChannelToken(jwt: '', userId: '', exp: 0);
          }),
        );
        async.flushMicrotasks();
        expect(error, isA<AuthSessionException>());
        expect(session.token, null);
        async.elapse(const Duration(seconds: 5));
        expect(session.userId, null);
        expect(async.pendingTimers, isEmpty);
        unawaited(session.close());
        async.flushMicrotasks();
      });
    },
  );
  test(
    'a reentrant signout cannot persist its discarded credential afterwards',
    () async {
      final storage = Storage();
      final session = AuthSession(
        AuthSessionOptions(
          storage: storage,
          fetchServerTime: () =>
              Future.value(DateTime.fromMillisecondsSinceEpoch(0)),
        ),
      );
      addTearDown(session.close);
      final sub = session.changed.listen((token) {
        if (token != null) unawaited(session.signOut());
      });
      await expectLater(
        session.fromToken(jwt('a', 1000)),
        throwsA(isA<AuthSessionException>()),
      );
      await Future<void>.value();
      await Future<void>.value();
      expect(storage.value, null);
      await sub.cancel();
    },
  );
}
