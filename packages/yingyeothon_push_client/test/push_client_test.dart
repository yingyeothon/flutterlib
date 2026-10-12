import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

import 'fake_http_client.dart';

final class Messaging implements PushMessaging {
  final refresh = StreamController<String>.broadcast(sync: true);
  final deliveries = StreamController<PushMessage>.broadcast(sync: true);
  final List<String> topics = [];
  String? token = 'device1';
  Object? failure;
  Future<String?>? pendingToken;
  @override
  Stream<String> get tokenRefreshed => refresh.stream;
  @override
  Stream<PushMessage> get messages => deliveries.stream;
  @override
  Future<String?> getToken() async {
    if (failure != null) throw failure!;
    return pendingToken ?? Future.value(token);
  }

  @override
  Future<void> subscribe(String topic) async {
    if (failure != null) throw failure!;
    topics.add('+$topic');
  }

  @override
  Future<void> unsubscribe(String topic) async {
    if (failure != null) throw failure!;
    topics.add('-$topic');
  }

  Future<void> close() async {
    await refresh.close();
    await deliveries.close();
  }
}

PushClient create(
  FakeHttp h, {
  Messaging? messaging,
  Uri? base,
  String token = 'fixture',
  String project = 'demo-project',
  String topic = 'configured.topic',
  Duration timeout = const Duration(seconds: 1),
}) => PushClient(
  PushClientOptions(
    apiBase: base ?? Uri.parse('http://fake/base'),
    channelId: 'push_demo',
    token: token,
    topic: topic,
    project: project,
    messaging: messaging,
    client: h,
    timeout: timeout,
  ),
);
void main() {
  late FakeHttp h;
  late Messaging m;
  late PushClient c;
  setUp(() {
    h = FakeHttp();
    m = Messaging();
    c = create(h, messaging: m);
  });
  tearDown(() async {
    await c.close();
    await m.close();
  });
  test(
    'startup registers every time, refresh re-registers, signout removes both',
    () async {
      h.answer(204);
      await c.start();
      h.answer(204);
      await c.start();
      expect(m.topics, ['+configured.topic']);
      final values = <ClassifiedPush>[];
      final sub = c.received.listen(values.add);
      m.deliveries.add(
        PushMessage(
          data: {
            'channelId': 'match_demo',
            'matchId': 'm1',
            'state': 'proposed',
          },
          title: 'Ready',
        ),
      );
      m.deliveries.add(PushMessage(data: {'campaign': 'one'}));
      expect(values, [isA<MatchPush>(), isA<MessagePush>()]);
      expect((values.first as MatchPush).channelId, 'match_demo');
      expect((values.first as MatchPush).matchId, 'm1');
      expect((values.first as MatchPush).state, 'proposed');
      h.answer(204);
      m.refresh.add('device2');
      for (var n = 0; n < 20; n++) {
        await Future<void>.value();
      }
      expect(h.requests, hasLength(3));
      h.answer(204);
      await c.unregister();
      expect(h.requests.map((r) => r.method), ['PUT', 'PUT', 'PUT', 'DELETE']);
      expect(h.requests.map((r) => jsonDecode(r.body)), [
        {'token': 'device1', 'project': 'demo-project'},
        {'token': 'device1', 'project': 'demo-project'},
        {'token': 'device2', 'project': 'demo-project'},
        {'token': 'device2'},
      ]);
      expect(
        h.requests.every(
          (r) =>
              r.headers['authorization'] == 'Bearer fixture' &&
              r.headers['content-type'] == 'application/json' &&
              !r.followRedirects,
        ),
        true,
      );
      expect(
        h.requests.every((r) => r.url.path == '/base/push/push_demo/token'),
        true,
      );
      expect(m.topics, ['+configured.topic', '-configured.topic']);
      expect(h.closed, false);
      await sub.cancel();
      m.refresh.add('ignored');
      expect(h.requests, hasLength(4));
    },
  );
  test(
    'manual registration and absent device token need no topic subscription',
    () async {
      final manual = create(h);
      await expectLater(manual.start(), throwsStateError);
      h.answer(204);
      await manual.register('token');
      h.answer(204);
      await manual.unregister();
      await manual.close();
      m.token = null;
      await c.start();
      expect(h.requests, hasLength(2));
    },
  );
  test('registration refusal does not subscribe; diagnostics never carry device text', () async {
    for (final status in [400, 401, 409, 429, 503]) {
      h.answer(
        status,
        '{"error":{"code":"push_project_refused","details":{"reason":"http://secret"}}}',
      );
      await expectLater(
        c.register('private-device'),
        throwsA(
          isA<PushException>()
              .having(
                (e) => e.toString(),
                'safe',
                'PushException(push_project_refused, $status)',
              )
              .having((e) => e.reason, 'reason', null),
        ),
      );
    }
    expect(m.topics, isEmpty);
    h.answer(503, '');
    await expectLater(
      c.register('private-device'),
      throwsA(isA<PushException>().having((e) => e.code, 'code', 'http_503')),
    );
  });
  test(
    'signout unsubscribes even when DELETE failed, and retains token for retry',
    () async {
      h.answer(204);
      await c.start();
      h.answer(503);
      await expectLater(c.unregister(), throwsA(isA<PushException>()));
      expect(m.topics, ['+configured.topic', '-configured.topic']);
      h.answer(204);
      await c.unregister();
      expect(jsonDecode(h.requests.last.body), {'token': 'device1'});
    },
  );
  test(
    'device failures are sanitized and refresh failures are events',
    () async {
      m.failure = const SocketException('secret');
      await expectLater(
        c.start(),
        throwsA(isA<PushException>().having((e) => e.code, 'code', 'device')),
      );
      m.failure = null;
      h.answer(204);
      await c.start();
      final errors = <PushException>[];
      final sub = c.refused.listen(errors.add);
      h.answer(401);
      final refused = c.refused.first;
      m.refresh.add('next');
      await refused;
      await Future<void>.value();
      await Future<void>.value();
      // Waiting for the serialized command drains its refresh predecessor.
      h.answer(204);
      await c.unregister();
      expect(errors.single.status, 401);
      await sub.cancel();
      m.failure = StateError('secret');
      h.answer(204);
      await expectLater(c.register('next'), throwsA(isA<PushException>()));
      m.failure = ArgumentError('secret');
      await expectLater(c.start(), throwsA(isA<PushException>()));
    },
  );
  test(
    'unregister invalidates refreshes queued behind an in-flight PUT',
    () async {
      final blocked = BlockingHttp()
        ..answer(204)
        ..answer(204);
      final local = create(blocked, messaging: m);
      addTearDown(local.close);
      final starting = local.start();
      await blocked.entered.future;
      final signout = local.unregister();
      m.refresh.add('stale-after-signout');
      blocked.released.complete();
      await starting;
      await signout;
      expect(blocked.requests.map((r) => r.method), ['PUT', 'DELETE']);
      expect(m.topics, isEmpty);
    },
  );
  test('unregister invalidates an outstanding startup token lookup', () async {
    final lookup = Completer<String?>();
    m.pendingToken = lookup.future;
    final starting = c.start();
    await c.unregister();
    lookup.complete('stale');
    await starting;
    expect(h.requests, isEmpty);
    expect(m.topics, isEmpty);
  });
  test('invalid asynchronous refresh is a safe refusal event', () async {
    h.answer(204);
    await c.start();
    final next = c.refused.first;
    m.refresh.add('');
    expect((await next).code, 'device');
  });
  test('message classification ignores malformed wakes and preserves public messages', () {
    for (final state in ['proposed', 'confirmed', 'expired', 'failed']) {
      expect(
        classifyPush(
          PushMessage(
            data: {'channelId': 'm', 'matchId': 'id', 'state': state},
          ),
        ),
        isA<MatchPush>(),
      );
    }
    expect(
      classifyPush(
        PushMessage(
          data: {'channelId': 'm', 'matchId': '', 'state': 'expired'},
        ),
      ),
      isA<MatchPush>(),
    );
    for (final data in [
      <String, String>{},
      {'channelId': 'm', 'state': 'confirmed'},
      {'channelId': 'm', 'matchId': 'id', 'state': 'future'},
      {'channelId': '', 'matchId': 'id', 'state': 'proposed'},
    ]) {
      expect(classifyPush(PushMessage(data: data)), isA<MessagePush>());
    }
  });
  test('token and option grammar is refused without quoting inputs', () async {
    for (final token in ['', 'a b', 'a' * 513]) {
      expect(() => c.register(token), throwsArgumentError);
    }
    for (final base in [
      Uri.parse('file:///x'),
      Uri.parse('http://host/#secret'),
    ]) {
      expect(() => create(h, base: base), throwsArgumentError);
    }
    expect(() => create(h, token: 'bad\n'), throwsArgumentError);
    expect(() => create(h, project: 'INVALID!'), throwsArgumentError);
    expect(() => create(h, topic: ''), throwsArgumentError);
    expect(() => create(h, timeout: Duration.zero), throwsArgumentError);
    await c.close();
    expect(() => c.register('token'), throwsStateError);
    await expectLater(c.start(), throwsStateError);
  });
  test('all transport failures and oversized bodies are safe', () async {
    for (final failure in [
      const SocketException('secret'),
      FormatException('secret'),
      ArgumentError('secret'),
      StateError('secret'),
    ]) {
      h.fail(failure);
      await expectLater(c.register('device'), throwsA(isA<PushException>()));
    }
    h.answer(204, 'x' * ((1 << 20) + 1));
    await expectLater(c.register('device'), throwsA(isA<PushException>()));
    h.answerChunked(204, 'x' * ((1 << 20) + 1));
    await expectLater(c.register('device'), throwsA(isA<PushException>()));
  });
  test('a hanging request times out and close removes every timer', () {
    fakeAsync((async) {
      final localHttp = FakeHttp()..stallBody(204);
      final localClient = create(localHttp);
      Object? error;
      unawaited(
        localClient.register('device').catchError((Object e) {
          error = e;
        }),
      );
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(error, isA<PushException>());
      expect(localHttp.aborted, [true]);
      expect(async.pendingTimers, isEmpty);
      unawaited(localClient.close());
      async.flushMicrotasks();
    });
  });
  test('SDK stream errors report safe device failures', () async {
    h.answer(204);
    await c.start();
    final errors = <PushException>[];
    final sub = c.refused.listen(errors.add);
    m.refresh.addError(StateError('private'));
    m.deliveries.addError(StateError('private'));
    expect(errors.map((e) => e.code), ['device', 'device']);
    await sub.cancel();
  });
}
