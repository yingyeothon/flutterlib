import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_game_kit/yingyeothon_game_kit.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

import 'support/harness.dart';

void main() {
  late MemoryHttp http;
  late MemoryHub hub;
  final kits = <GameKit>[];
  final aId = 'a' * 32, bId = 'b' * 32;
  setUp(() {
    http = MemoryHttp();
    hub = MemoryHub();
  });
  tearDown(() async {
    for (final kit in kits.reversed) {
      await kit.close();
    }
    kits.clear();
  });
  Future<GameKit> create(
    String user, {
    QueueStorage? queue,
    bool deferred = false,
    Messaging? messaging,
    Map<String, KitMerge> policies = const {},
  }) async {
    final kit = GameKit(
      GameKitOptions(
        config: config(deferred: deferred),
        client: http,
        webSocketFactory: hub,
        queueStorage: queue,
        mergePolicies: policies,
        pushMessaging: messaging,
        firebaseProject: 'demo-project',
      ),
    );
    kits.add(kit);
    await kit.session.fromToken(jwt(user));
    return kit;
  }

  Future<void> room(GameKit a, GameKit b) async {
    final invites = b.room.invited.listen(
      (invite) => unawaited(invite.accept()),
    );
    addTearDown(invites.cancel);
    await a.room.create();
    await a.room.invite(bId);
    await drain();
    expect(b.room.id, a.room.id);
    http.online = hub.sockets.keys.toSet();
  }

  test('cached content, stream versions and lifecycle pause', () async {
    http.seed('content', '', 'tuning', {'speed': 1});
    final kit = await create(aId);
    expect(await kit.content.get('tuning'), {'speed': 1});
    http.rows['content//tuning']!.value = {'speed': 2};
    http.rows['content//tuning']!.version = 2;
    expect(await kit.content.get('tuning'), {'speed': 1});
    await drain();
    expect(await kit.content.get('tuning'), {'speed': 2});
    final seen = <Object?>[];
    final sub = kit.content.subscribe('tuning').listen(seen.add);
    await drain();
    http.rows['content//tuning']!.version++;
    http.rows['content//tuning']!.value = 3;
    kit.setForeground(false);
    kit.setForeground(true);
    await drain();
    expect(seen.last, 3);
    expect(await kit.content.list(prefix: 'tun'), {'tuning': 3});
    kit.setForeground(false);
    await sub.cancel();
  });
  test(
    'save CAS, merge, update, remove, counter, claim and missing values',
    () async {
      final a = await create(aId), b = await create(aId);
      await a.save.load('k');
      await b.save.load('k');
      await a.save.store('k', 1);
      await expectLater(
        b.save.store('k', 2),
        throwsA(isA<KitError>().having((e) => e.code, 'code', 'conflict')),
      );
      await b.save.store(
        'k',
        2,
        merge: (local, remote) => (local as int) + (remote as int),
      );
      expect(await a.save.load('k'), 3);
      await a.save.update('k', (value) => (value as int) + 1);
      expect(await b.save.load('k'), 4);
      expect(await a.save.counter('coins').add(2, min: 0, max: 3), 2);
      await expectLater(
        a.save.counter('coins').add(-3, min: 0),
        throwsA(isA<KitError>().having((e) => e.code, 'code', 'out_of_range')),
      );
      expect(await a.save.claimOnce('daily', 10), true);
      expect(await a.save.claimOnce('daily', 10), false);
      http.now += 10;
      expect(await a.save.claimOnce('daily', 10), true);
      await a.save.remove('k');
      await a.save.remove('k');
      expect(await a.save.load('k'), null);
      await a.save.store('null', null);
      expect(await a.save.load('null'), null);
      await expectLater(
        a.save.store('too-big', 'x' * 16384),
        throwsArgumentError,
      );
      await expectLater(
        a.save.store('bad-ttl', 1, ttl: -1),
        throwsArgumentError,
      );
      expect(a.save.pendingCount, 0);
      await a.save.flush();
    },
  );
  test('durable offline writes replay in order across restoration, names and users', () async {
    final queue = QueueStorage();
    final a = await create(
      aId,
      queue: queue,
      policies: {'k': (l, r) => (l as int) + (r as int)},
    );
    await a.save.store('k', 1);
    http.offline = true;
    await a.save.store('k', 2);
    await a.save.store('k', 3);
    expect(a.save.pendingCount, 2);
    expect(await a.save.load('k'), 3);
    http.offline = false;
    await a.save.flush();
    expect(await a.save.load('k'), 3);
    expect(a.save.pendingCount, 0);
    http.offline = true;
    await a.save.store('k', 4);
    await a.close();
    kits.remove(a);
    http.offline = false;
    final restored = await create(aId, queue: queue);
    expect(await restored.save.load('k'), 4);
    await restored.save.flush();
    expect(restored.save.pendingCount, 0);
    final other = await create(bId, queue: queue);
    expect(await other.save.load('k'), null);
    queue.fail = true;
    await expectLater(other.save.store('x', 1), throwsA(isA<KitError>()));
  });
  test('lost acknowledgement is recovered, conflict survives and merge intent is durable', () async {
    final queue = QueueStorage(), a = await create(aId, queue: QueueStorage());
    await a.save.store('k', 1);
    final b = await create(
      aId,
      queue: queue,
      policies: {'k': (l, r) => (l as int) + (r as int)},
    );
    await b.save.load('k');
    http.offline = true;
    await b.save.store('k', 2);
    http.offline = false;
    await a.save.store('k', 5);
    await b.save.flush();
    expect(await b.save.load('k'), 7);
    expect(b.save.pendingCount, 0);
    http.offline = true;
    await b.save.store('k', 8);
    http.offline = false;
    // Simulate server success with lost acknowledgement before reconstruction.
    http.rows['save/$aId/k']!.value = 8;
    http.rows['save/$aId/k']!.version++;
    await b.save.flush();
    expect(b.save.pendingCount, 0);
    await b.save.load('k');
    http.offline = true;
    await b.save.store('k', 9);
    http.offline = false;
    await a.save.load('k');
    await a.save.store('k', 10);
    final noMerge = await create(aId, queue: queue);
    await expectLater(
      noMerge.save.flush(),
      throwsA(isA<KitError>().having((e) => e.code, 'code', 'conflict')),
    );
    expect(noMerge.save.pendingCount, 1);
  });
  test('room events, host state, resync and foreground reconnect', () async {
    final a = await create(aId), b = await create(bId);
    await room(a, b);
    final games = <KitRoomEvent>[];
    final sub = b.room.events.listen(games.add);
    await a.room.send('move', {'x': 1});
    expect(games.single.from, aId);
    expect(games.single.payload, {'x': 1});
    await a.room.whisper(bId, 'private', 2);
    expect(games.last.name, 'private');
    await expectLater(a.room.send('kit.reserved', null), throwsArgumentError);
    await expectLater(
      a.room.send('large', 'x' * 8193),
      throwsA(isA<KitError>()),
    );
    final states = <Object?>[];
    final stateSub = b.room.state.listen(states.add);
    await a.room.publish({'hp': 5});
    expect(states, [
      {'hp': 5},
    ]);
    final replay = b.room.state.first;
    await b.room.resync();
    await replay;
    expect(states.length, 2);
    await expectLater(b.room.publish(1), throwsA(isA<KitError>()));
    b.setForeground(false);
    await drain();
    b.setForeground(true);
    await drain();
    expect(b.room.id, a.room.id);
    final hosted = b.room.becameHost.first;
    await a.room.leave();
    expect(await hosted, {'hp': 5});
    await sub.cancel();
    await stateSub.cancel();
  });
  test(
    'room local refusal settles pending command and authenticates envelopes',
    () async {
      final a = await create(aId);
      await a.room.create();
      await expectLater(
        a.room.invite(bId),
        throwsA(isA<KitError>().having((e) => e.code, 'code', 'offline')),
      );
      final events = <KitRoomEvent>[];
      final sub = a.room.events.listen(events.add);
      hub.sockets[aId]!.serverSend({
        'type': 'event',
        'from': bId,
        'scope': 'party',
        'name': 'move',
        'payload': {
          'v': 1,
          'roomId': a.room.id,
          'senderSession': 's',
          'seq': 1,
          'data': 'forged',
        },
      });
      expect(events, isEmpty);
      await sub.cancel();
    },
  );
  test(
    'turns alternate, hash vectors, replay, own result and score sinks',
    () async {
      final a = await create(aId), b = await create(bId);
      await room(a, b);
      Object? apply(Object? state, Object? move, String by) =>
          (state as int) + (move as int);
      final ga = await a.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
        resultBoard: 'weekly',
        scoreForResult: (r) => r as int,
      );
      final gb = await b.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
      );
      await expectLater(
        gb.submit(1),
        throwsA(isA<KitError>().having((e) => e.code, 'code', 'not_your_turn')),
      );
      await ga.submit(1);
      await gb.submit(2);
      expect(ga.state, 3);
      expect(gb.state, 3);
      expect(gb.index, 2);
      expect(ga.elapsed.keys, contains(aId));
      await gb.resync();
      expect(gb.state, 3);
      await ga.finish(10);
      await drain();
      expect((await a.save.load('result')) as Map, containsPair('result', 10));
      expect((await a.board('weekly').me('alltime'))!.score, 10);
      await ga.finish(10);
      await expectLater(ga.finish(11), throwsA(isA<KitError>()));
      await expectLater(gb.finish(10), throwsA(isA<KitError>()));
      expect(ga.frozen, false);
    },
  );
  test(
    'tampered turns freeze mismatch and local rejected moves never send',
    () async {
      final a = await create(aId), b = await create(bId);
      await room(a, b);
      Object? apply(Object? state, Object? move, String by) {
        if (move == 'bad') throw StateError('private');
        return (state as int) + (move as int);
      }

      final ga = await a.turns.start(initial: 0, apply: apply);
      final gb = await b.turns.start(initial: 0, apply: apply);
      final before = hub.sent.length;
      await expectLater(ga.submit('bad'), throwsA(isA<KitError>()));
      expect(hub.sent, hasLength(before));
      final mismatch = gb.mismatch.first;
      hub.tamper = {
        'gameId':
            (hub.sent
                        .firstWhere((e) => e.frame['name'] == 'kit.turns.start')
                        .frame['payload']!
                    as Map)['data']!
                as Object,
      };
      // Use the legitimate game id but a forged move hash.
      final start =
          (hub.sent
                      .firstWhere((e) => e.frame['name'] == 'kit.turns.start')
                      .frame['payload']!
                  as Map)['data']!
              as Map;
      hub.tamper = {
        'gameId': start['gameId'],
        'index': 0,
        'move': 1,
        'by': aId,
        'hash': '0' * 64,
      };
      await expectLater(ga.submit(1), throwsA(isA<KitError>()));
      expect((await mismatch).code, 'mismatch');
      expect(gb.frozen, true);
    },
  );
  test('board, mail claim race and profiles/social wrapper paths', () async {
    final a = await create(aId),
        b = await create(bId),
        secondB = await create(bId);
    await room(a, b);
    await a.board('weekly').info();
    expect(a.board('weekly').periods, ['alltime', 'weekly']);
    expect(a.board('weekly').rule, 'best');
    expect(a.board('weekly').order, 'desc');
    expect(await b.board('weekly').me('weekly'), null);
    expect(await b.board('weekly').around('weekly'), isEmpty);
    expect(await a.board('weekly').submit(12), hasLength(2));
    expect((await a.board('weekly').around('alltime')).single.rank, 1);
    await expectLater(
      a.board('weekly').around('alltime', span: -1),
      throwsArgumentError,
    );
    await expectLater(a.board('server').submit(1), throwsA(isA<KitError>()));
    await a.mail.send(bId, {'reward': 1});
    final letter = (await b.mail.list()).single;
    expect((await b.mail.read(letter.id))!.from, aId);
    final claimed = await Future.wait([
      b.mail.claim(letter.id).then<Object?>((v) => v, onError: (Object e) => e),
      secondB.mail
          .claim(letter.id)
          .then<Object?>((v) => v, onError: (Object e) => e),
    ]);
    expect(claimed.whereType<KitLetter>(), hasLength(1));
    expect(claimed.whereType<KitError>().single.code, 'already_claimed');
    await expectLater(b.mail.claim(letter.id), throwsA(isA<KitError>()));
    await b.mail.remove(letter.id);
    expect(await a.friends.myProfile(), null);
    await a.friends.setProfile('Alice');
    await b.friends.setProfile('Bob');
    expect((await a.friends.myProfile())!.displayName, 'Alice');
    expect(await a.friends.profiles([bId]), hasLength(1));
    await expectLater(
      a.friends.profiles(List.filled(51, bId)),
      throwsArgumentError,
    );
    await a.friends.request(bId);
    expect((await b.friends.requests()).incoming, [aId]);
    await b.friends.accept(aId);
    expect((await a.friends.list()).single.online, true);
    await a.friends.invite(bId);
    await b.friends.remove(aId);
    await a.friends.request(bId);
    await b.friends.decline(aId);
    await b.friends.block(aId);
    await b.friends.unblock(aId);
  });
  test(
    '401 from any module signs out once and stops shared resources',
    () async {
      final kit = await create(aId);
      final outs = <void>[];
      final sub = kit.session.signedOut.listen(outs.add);
      http.failNext = 401;
      await expectLater(
        kit.save.load('k'),
        throwsA(isA<KitError>().having((e) => e.code, 'code', 'signed_out')),
      );
      expect(kit.session.token, null);
      expect(outs, hasLength(1));
      await sub.cancel();
    },
  );
  test(
    'missing configuration refuses on first module operation and bad options',
    () async {
      final kit = GameKit(
        GameKitOptions(config: GameKitConfig({}), client: http),
      );
      kits.add(kit);
      await kit.session.fromToken(jwt(aId));
      for (final operation in <Future<Object?> Function()>[
        () => kit.content.get('x'),
        () => kit.save.load('x'),
        () => kit.room.create(),
        () => kit.board('x').info(),
        () => kit.mail.list(),
        () => kit.friends.list(),
        () => kit.push.start(),
      ]) {
        try {
          await operation();
          fail('expected failure');
        } on KitError catch (e) {
          expect(e.code, 'not_configured');
        }
      }
      await expectLater(kit.matchmaking.find(), throwsA(isA<KitError>()));
      expect(
        () => GameKit(
          GameKitOptions(
            config: config(),
            contentInterval: Duration.zero,
            client: http,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => GameKit(
          GameKitOptions(
            config: config(),
            matchInterval: const Duration(milliseconds: 1),
            client: http,
          ),
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'foreground polling suppresses duplicates and stops timers on close',
    () {
      fakeAsync((async) {
        final h = MemoryHttp()..seed('content', '', 'key', 1);
        final k = GameKit(
          GameKitOptions(
            config: config(),
            client: h,
            monotonicMilliseconds: () => async.elapsed.inMilliseconds,
            contentInterval: const Duration(seconds: 2),
            mailInterval: const Duration(seconds: 2),
          ),
        );
        unawaited(k.session.fromToken(jwt(aId)));
        async.flushMicrotasks();
        final seen = <Object?>[];
        final sub = k.content.subscribe('key').listen(seen.add);
        async.flushMicrotasks();
        expect(seen, [1]);
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(seen, [1]);
        h.rows['content//key']!.version++;
        h.rows['content//key']!.value = 2;
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(seen, [1, 2]);
        k.setForeground(false);
        final requests = h.requests.length;
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(h.requests, hasLength(requests));
        unawaited(sub.cancel());
        unawaited(k.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    },
  );
  test(
    'push adapter registers configured topic and identity signout cleans token',
    () async {
      final messaging = Messaging();
      addTearDown(messaging.close);
      final kit = await create(aId, messaging: messaging);
      final seen = <KitMessage>[];
      final sub = kit.push.received.listen(seen.add);
      await kit.push.start();
      messaging.delivery.add(
        PushMessage(
          data: {'channelId': 'match', 'matchId': '', 'state': 'expired'},
        ),
      );
      expect(seen.single.matchWake, true);
      expect(messaging.topics, ['+configured.topic']);
      await kit.session.signOut();
      await drain();
      expect(messaging.topics, ['+configured.topic', '-configured.topic']);
      expect(http.push.tokenCount, 0);
      await sub.cancel();
    },
  );
  test('immutable persistence snapshots survive an opponent turn during a chunk PUT', () async {
    final a = await create(aId), b = await create(bId);
    await room(a, b);
    Object? apply(Object? state, Object? move, String by) =>
        (state as int) + (move as int);
    final ga = await a.turns.start(initial: 0, apply: apply, persist: true),
        gb = await b.turns.start(initial: 0, apply: apply, persist: true);
    final entered = Completer<void>(), released = Completer<void>();
    var held = false;
    http.beforeSend = (request) async {
      if (!held &&
          request.method == 'PUT' &&
          identity(request.headers['authorization']!.substring(7)) == aId &&
          request.url.pathSegments.last.split(':').length > 3) {
        held = true;
        entered.complete();
        await released.future;
      }
    };
    final first = ga.submit(1);
    await entered.future;
    await gb.submit(2);
    expect(ga.index, 2);
    released.complete();
    await first;
    // The first revision is a valid one-move snapshot, never chunks1/count2.
    final prefix = 'save/$aId/turns:${a.room.id}';
    final manifest = http.rows[prefix]!.value! as Map;
    final chunk =
        http
                .rows['$prefix:${manifest['gameId']}:${manifest['revision']}:0']!
                .value!
            as List;
    expect(manifest['count'], chunk.length);
    await Future.wait([ga.resync(), ga.resync()]);
    expect(ga.index, 2);
    expect(ga.frozen, false);
    await ga.finish(3);
    expect((http.rows[prefix]!.value! as Map)['count'], 2);
  });
  test(
    'rank hydration failure never repeats an acknowledged sum-board finish',
    () async {
      final a = await create(aId), b = await create(bId);
      await room(a, b);
      http.sumBoards.add('weekly');
      Object? apply(Object? state, Object? move, String by) =>
          (state as int) + (move as int);
      final ga = await a.turns.start(
        initial: 0,
        apply: apply,
        resultBoard: 'weekly',
        scoreForResult: (r) => r as int,
      );
      await b.turns.start(initial: 0, apply: apply);
      http.failWhen = (request) =>
          request.method == 'GET' &&
              request.url.path.contains('/lb/weekly/scores/')
          ? 503
          : null;
      await ga.finish(10);
      await ga.finish(10);
      expect(http.scores['weekly']![aId], 10);
      expect(
        http.requests.where(
          (r) => r.method == 'PUT' && r.url.path.contains('/lb/weekly/'),
        ),
        hasLength(1),
      );
    },
  );
  test('invalid peer Unicode freezes turns without escaping its stream listener', () async {
    final a = await create(aId), b = await create(bId);
    await room(a, b);
    Object? apply(Object? state, Object? move, String by) => move;
    await a.turns.start(initial: 0, apply: apply);
    final gb = await b.turns.start(initial: 0, apply: apply);
    final start =
        (hub.sent
                    .firstWhere((e) => e.frame['name'] == 'kit.turns.start')
                    .frame['payload']!
                as Map)['data']!
            as Map;
    final mismatch = gb.mismatch.first;
    hub.sockets[bId]!.serverSendRaw(
      '{"type":"event","from":"$aId","scope":"party","name":"kit.turn","payload":{"v":1,"roomId":"${b.room.id}","senderSession":"bad-unicode","seq":1,"data":{"gameId":"${start['gameId']}","index":0,"move":"\\ud800","by":"$aId","hash":"${'0' * 64}"}}}',
    );
    expect((await mismatch).code, 'mismatch');
    expect(gb.frozen, true);
  });
  test('stale deferred 401 cannot sign out a replacement identity', () async {
    final kit = await create(aId, deferred: true);
    final entered = Completer<void>(), released = Completer<void>();
    var held = false;
    http.beforeSend = (request) async {
      if (!held && request.url.path == '/m/match/ticket') {
        held = true;
        entered.complete();
        await released.future;
      }
    };
    http.failWhen = (request) =>
        request.url.path == '/m/match/ticket' &&
            identity(request.headers['authorization']!.substring(7)) == aId
        ? 401
        : null;
    final stale = kit.matchmaking.status();
    final assertion = expectLater(
      stale,
      throwsA(isA<KitError>().having((e) => e.code, 'code', 'signed_out')),
    );
    await entered.future;
    await kit.session.fromToken(jwt(bId));
    released.complete();
    await assertion;
    expect(kit.session.userId, bId);
  });
  test('cooldown retries release the request lane and cancel prevents a later POST', () {
    fakeAsync((async) {
      final h = MemoryHttp();
      final k = GameKit(
        GameKitOptions(
          config: config(deferred: true),
          client: h,
          monotonicMilliseconds: () => async.elapsed.inMilliseconds,
        ),
      );
      unawaited(k.session.fromToken(jwt(aId)));
      async.flushMicrotasks();
      h.scripted.add((
        429,
        {
          'error': {
            'code': 'rate_limited',
            'details': {'reason': 'cooldown', 'retryAfter': 30},
          },
        },
      ));
      Object? canceled;
      unawaited(
        k.matchmaking.submit().catchError((Object e) {
          canceled = e;
          return const KitMatchStatus(state: 'failed');
        }),
      );
      async.flushMicrotasks();
      unawaited(k.matchmaking.cancel());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(
        canceled,
        isA<KitError>().having((e) => e.code, 'code', 'cancelled'),
      );
      expect(
        h.requests
            .where((r) => r.url.path == '/m/match/ticket')
            .map((r) => r.method),
        ['POST', 'DELETE'],
      );
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      expect(h.requests.where((r) => r.method == 'POST'), hasLength(1));
      unawaited(k.close());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
  test('restored waiting tickets poll, push wake is paced, and background stops requests', () {
    fakeAsync((async) {
      final h = MemoryHttp();
      final m = Messaging();
      final k = GameKit(
        GameKitOptions(
          config: config(deferred: true),
          client: h,
          pushMessaging: m,
          firebaseProject: 'demo-project',
          monotonicMilliseconds: () => async.elapsed.inMilliseconds,
        ),
      );
      unawaited(k.session.fromToken(jwt(aId)));
      async.flushMicrotasks();
      h.matches['match'] = FakeMatchStore(clock: () => 1000)..submit(aId);
      unawaited(k.matchmaking.status());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      final before = h.requests
          .where((r) => r.url.path == '/m/match/ticket')
          .length;
      unawaited(k.push.start());
      async.flushMicrotasks();
      m.delivery.add(
        PushMessage(
          data: {'channelId': 'match', 'matchId': '', 'state': 'expired'},
        ),
      );
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(
        h.requests.where((r) => r.url.path == '/m/match/ticket').length,
        greaterThan(before),
      );
      k.setForeground(false);
      final stopped = h.requests.length;
      async.elapse(const Duration(seconds: 20));
      async.flushMicrotasks();
      expect(h.requests, hasLength(stopped));
      k.setForeground(true);
      async.flushMicrotasks();
      expect(h.requests.length, greaterThan(stopped));
      unawaited(k.close());
      unawaited(m.close());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
  test(
    'four live members form one room despite an invite arriving before matched',
    () async {
      final users = [aId, bId, 'c' * 32, 'd' * 32];
      final players = <GameKit>[];
      for (final id in users) {
        players.add(await create(id));
      }
      await Future.wait(players.map((kit) => kit.room.connect()));
      hub.delayedMatches.add(bId);
      final results = players.map((kit) => kit.matchmaking.find()).toList();
      await drain(150);
      expect(hub.pendingMatches.containsKey(bId), true);
      expect(
        hub.sent.any(
          (e) => e.frame['type'] == 'party.invite' && e.frame['userId'] == bId,
        ),
        true,
      );
      expect(players[1].room.id, null);
      hub.deliverMatch(bId);
      final matches = await Future.wait(results);
      expect(matches.every((m) => !m.partial && m.members.length == 4), true);
      expect(players.map((p) => p.room.id).toSet(), hasLength(1));
    },
  );
  test(
    'live callback result null forms no room and live cancel ends pending work',
    () async {
      hub.matchSize = 1;
      final kit = GameKit(
        GameKitOptions(
          config: config(),
          client: http,
          webSocketFactory: hub,
          matchCallback: true,
        ),
      );
      kits.add(kit);
      await kit.session.fromToken(jwt(aId));
      await kit.room.connect();
      expect((await kit.matchmaking.find()).result, null);
      expect(kit.room.id, null);
      hub.matchSize = 2;
      final find = kit.matchmaking.find();
      final assertion = expectLater(
        find,
        throwsA(isA<KitError>().having((e) => e.code, 'code', 'cancelled')),
      );
      await drain();
      await kit.matchmaking.cancel();
      await assertion;
      final deferred = await create(bId, deferred: true);
      await expectLater(deferred.matchmaking.find(), throwsA(isA<KitError>()));
    },
  );
  test(
    'live partial returns only members who joined within thirty seconds',
    () {
      fakeAsync((async) {
        final h = MemoryHttp(),
            sockets = MemoryHub()
              ..matchSize = 1
              ..forcedMembers = [aId, bId];
        final a = GameKit(
          GameKitOptions(
            config: config(),
            client: h,
            webSocketFactory: sockets,
            monotonicMilliseconds: () => async.elapsed.inMilliseconds,
          ),
        );
        final b = GameKit(
          GameKitOptions(
            config: config(),
            client: h,
            webSocketFactory: sockets,
            monotonicMilliseconds: () => async.elapsed.inMilliseconds,
          ),
        );
        unawaited(a.session.fromToken(jwt(aId)));
        unawaited(b.session.fromToken(jwt(bId)));
        async.flushMicrotasks();
        unawaited(a.room.connect());
        unawaited(b.room.connect());
        async.flushMicrotasks();
        KitMatch? result;
        unawaited(a.matchmaking.find().then((value) => result = value));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(result!.partial, true);
        expect(result!.members, [aId]);
        unawaited(a.close());
        unawaited(b.close());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    },
  );
  test('socket reconnect automatically restores a missed turn while foreground stays true', () {
    fakeAsync((async) {
      final h = MemoryHttp(), sockets = MemoryHub();
      final a = GameKit(
        GameKitOptions(
          config: config(),
          client: h,
          webSocketFactory: sockets,
          monotonicMilliseconds: () => async.elapsed.inMilliseconds,
        ),
      );
      final b = GameKit(
        GameKitOptions(
          config: config(),
          client: h,
          webSocketFactory: sockets,
          monotonicMilliseconds: () => async.elapsed.inMilliseconds,
        ),
      );
      unawaited(a.session.fromToken(jwt(aId)));
      unawaited(b.session.fromToken(jwt(bId)));
      async.flushMicrotasks();
      final invited = b.room.invited.listen(
        (invite) => unawaited(invite.accept()),
      );
      unawaited(a.room.create());
      async.flushMicrotasks();
      unawaited(a.room.invite(bId));
      async.flushMicrotasks();
      Object? apply(Object? state, Object? move, String by) =>
          (state as int) + (move as int);
      KitTurnGame? ga, gb;
      unawaited(a.turns.start(initial: 0, apply: apply).then((g) => ga = g));
      async.flushMicrotasks();
      unawaited(b.turns.start(initial: 0, apply: apply).then((g) => gb = g));
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      expect(gb, isNotNull);
      sockets.sockets[bId]!.serverClose(4002);
      sockets.sockets.remove(bId);
      unawaited(ga!.submit(1));
      async.flushMicrotasks();
      expect(gb!.index, 0);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(gb!.index, 1);
      expect(gb!.frozen, false);
      unawaited(invited.cancel());
      unawaited(a.close());
      unawaited(b.close());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
  test(
    'spectators cannot become replay responders or supply terminal results',
    () async {
      final a = await create(aId),
          b = await create(bId),
          spectator = await create('c' * 32);
      await room(a, b);
      final invite = spectator.room.invited.listen(
        (i) => unawaited(i.accept()),
      );
      addTearDown(invite.cancel);
      await a.room.invite('c' * 32);
      await drain();
      Object? apply(Object? state, Object? move, String by) => move;
      await a.turns.start(initial: 0, apply: apply, players: [aId, bId]);
      final gb = await b.turns.start(
        initial: 0,
        apply: apply,
        players: [aId, bId],
        saveResultAs: 'result',
      );
      hub.dropNames.add('kit.turns.manifest');
      hub.dropNames.add('kit.turns.chunk');
      final recovery = gb.resync();
      await drain();
      final request =
          (hub.sent
                      .lastWhere((e) => e.frame['name'] == 'kit.turns.log')
                      .frame['payload']!
                  as Map)['data']!
              as Map;
      final manifest = <String, Object?>{
        'gameId': request['gameId'],
        'requestId': request['requestId'],
        'count': 0,
        'chunks': 0,
        'finalHash': '0' * 64,
      };
      hub.control('c' * 32, bId, 'kit.turns.manifest', manifest);
      hub.control('c' * 32, bId, 'kit.turns.finish', {
        ...manifest,
        'result': 'forged',
      });
      await drain();
      expect(gb.frozen, false);
      expect(await b.save.load('result'), null);
      hub.control(aId, bId, 'kit.turns.manifest', manifest);
      await recovery;
    },
  );
  test('missing log chunks time out without replacing verified state', () {
    fakeAsync((async) {
      final h = MemoryHttp(), sockets = MemoryHub();
      final a = GameKit(
        GameKitOptions(
          config: config(),
          client: h,
          webSocketFactory: sockets,
          monotonicMilliseconds: () => async.elapsed.inMilliseconds,
        ),
      );
      final b = GameKit(
        GameKitOptions(
          config: config(),
          client: h,
          webSocketFactory: sockets,
          monotonicMilliseconds: () => async.elapsed.inMilliseconds,
        ),
      );
      unawaited(a.session.fromToken(jwt(aId)));
      unawaited(b.session.fromToken(jwt(bId)));
      async.flushMicrotasks();
      final invited = b.room.invited.listen((i) => unawaited(i.accept()));
      unawaited(a.room.create());
      async.flushMicrotasks();
      unawaited(a.room.invite(bId));
      async.flushMicrotasks();
      Object? apply(Object? state, Object? move, String by) =>
          (state as int) + (move as int);
      KitTurnGame? ga, gb;
      unawaited(a.turns.start(initial: 0, apply: apply).then((g) => ga = g));
      async.flushMicrotasks();
      unawaited(b.turns.start(initial: 0, apply: apply).then((g) => gb = g));
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      async.flushMicrotasks();
      unawaited(ga!.submit(1));
      async.flushMicrotasks();
      sockets.dropNames.add('kit.turns.chunk');
      Object? error;
      unawaited(gb!.resync().catchError((Object e) => error = e));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(
        error,
        isA<KitError>().having((e) => e.code, 'code', 'unavailable'),
      );
      expect(gb!.index, 1);
      expect(gb!.frozen, false);
      unawaited(invited.cancel());
      unawaited(a.close());
      unawaited(b.close());
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
    });
  });
  test(
    'closed host restores a persisted game id and log without an online peer',
    () async {
      final a = await create(aId), b = await create(bId);
      await room(a, b);
      Object? apply(Object? state, Object? move, String by) =>
          (state as int) + (move as int);
      final ga = await a.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
      );
      final gb = await b.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
      );
      await ga.submit(1);
      await gb.submit(2);
      await drain();
      final roomId = a.room.id;
      final before = http.rows['save/$aId/turns:$roomId']!.value! as Map;
      await a.close();
      kits.remove(a);
      await b.close();
      kits.remove(b);
      final restored = await create(aId);
      await restored.room.connect();
      final game = await restored.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
      );
      expect(game.index, 2);
      expect(game.state, 3);
      expect(game.finished, false);
      final manifest = http.rows['save/$aId/turns:$roomId']!.value! as Map;
      expect(manifest['gameId'], before['gameId']);
      await game.finish('done');
      await restored.close();
      kits.remove(restored);
      final finalKit = await create(aId);
      await finalKit.room.connect();
      final finished = await finalKit.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
      );
      expect(finished.finished, true);
      expect(finished.result, 'done');
      await expectLater(finished.submit(1), throwsA(isA<KitError>()));
      final fresh = await finalKit.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        resume: false,
      );
      expect(fresh.index, 0);
      expect(
        (http.rows['save/$aId/turns:$roomId']!.value! as Map)['gameId'],
        isNot(before['gameId']),
      );
    },
  );
  test(
    'finished follower retries own result when the host is unavailable',
    () async {
      final a = await create(aId), b = await create(bId);
      await room(a, b);
      Object? apply(Object? state, Object? move, String by) => move;
      final ga = await a.turns.start(initial: 0, apply: apply);
      final gb = await b.turns.start(
        initial: 0,
        apply: apply,
        saveResultAs: 'result',
      );
      http.failWhen = (request) =>
          request.method == 'PUT' && request.url.path.endsWith('/result')
          ? 503
          : null;
      await ga.finish('won');
      await drain();
      expect(gb.finished, true);
      expect(http.rows['save/$bId/result'], null);
      await a.close();
      kits.remove(a);
      http.failWhen = null;
      b.setForeground(false);
      await drain();
      b.setForeground(true);
      await drain(200);
      expect((http.rows['save/$bId/result']!.value! as Map)['result'], 'won');
    },
  );
  test('concurrent room connects during backoff create only one replacement client', () async {
    final a = await create(aId);
    await a.room.create();
    final old = hub.sockets[aId]!;
    old.serverClose(4002);
    final count = hub.sent.where((e) => e.frame['type'] == 'party.list').length;
    await Future.wait([a.room.connect(), a.room.connect(), a.room.connect()]);
    expect(
      hub.sent.where((e) => e.frame['type'] == 'party.list').length,
      count + 1,
    );
    expect(hub.sockets[aId], isNot(same(old)));
    // The server already closed this transport; replacing it must not reopen it.
    expect(old.isClosed, true);
  });
  test('persistent finished bootstrap reads receipt before replay or sum submission', () async {
    final a = await create(aId), b = await create(bId);
    await room(a, b);
    http.sumBoards.add('weekly');
    Object? apply(Object? state, Object? move, String by) => move;
    Future<KitTurnGame> start(GameKit kit) => kit.turns.start(
      initial: 0,
      apply: apply,
      persist: true,
      saveResultAs: 'result',
      resultBoard: 'weekly',
      scoreForResult: (result) => result as int,
    );
    final ga = await start(a);
    await start(b);
    await ga.finish(10);
    await drain();
    final restored = await start(a);
    await start(b);
    await drain();
    expect(restored.finished, true);
    expect(restored.result, 10);
    expect(http.scores['weekly']![aId], 10);
    expect(http.scores['weekly']![bId], 10);
    expect(
      http.requests.where(
        (r) => r.method == 'PUT' && r.url.path.contains('/lb/weekly/'),
      ),
      hasLength(2),
    );
  });
  test(
    'simultaneous persistent recovery releases verified fallback replay',
    () {
      fakeAsync((async) {
        var complete = false;
        var stage = 'create';
        final task = () async {
          final a = await create(aId), b = await create(bId);
          await room(a, b);
          Object? apply(Object? state, Object? move, String by) => move;
          final ga = await a.turns.start(
            initial: 0,
            apply: apply,
            persist: true,
          );
          await b.turns.start(initial: 0, apply: apply, persist: true);
          stage = 'submit';
          await ga.submit(7);
          await drain();
          stage = 'recover';
          final restored = await Future.wait([
            a.turns.start(initial: 0, apply: apply, persist: true),
            b.turns.start(initial: 0, apply: apply, persist: true),
          ]);
          expect(restored.map((g) => g.state), [7, 7]);
          complete = true;
          await Future.wait(kits.map((k) => k.close()));
        }();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(complete, true, reason: stage);
        expect(async.pendingTimers, isEmpty);
        unawaited(task);
      });
    },
  );
  test(
    'old receipt never revokes an acknowledged newly configured board',
    () async {
      final a = await create(aId), b = await create(bId);
      await room(a, b);
      http.sumBoards.add('weekly');
      Object? apply(Object? state, Object? move, String by) => move;
      final ga = await a.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
      );
      await b.turns.start(initial: 0, apply: apply);
      await ga.finish(10);
      final recovered = await a.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
        resultBoard: 'weekly',
        scoreForResult: (r) => r as int,
      );
      http.failWhen = (r) =>
          r.method == 'PUT' && r.url.path.endsWith('/result') ? 503 : null;
      await expectLater(recovered.finish(10), throwsA(isA<KitError>()));
      http.failWhen = null;
      await recovered.finish(10);
      expect((http.rows['save/$aId/result']!.value! as Map)['board'], 'weekly');
      final again = await a.turns.start(
        initial: 0,
        apply: apply,
        persist: true,
        saveResultAs: 'result',
        resultBoard: 'weekly',
        scoreForResult: (r) => r as int,
      );
      await again.finish(10);
      expect(http.scores['weekly']![aId], 10);
    },
  );
  test(
    'full UTF-8 envelope passes at 8192 bytes and refuses one byte over',
    () async {
      final a = await create(aId);
      await a.room.create();
      await a.room.send('boundary', '');
      final payload =
          hub.sent
                  .lastWhere((e) => e.frame['name'] == 'boundary')
                  .frame['payload']!
              as Map<String, Object?>;
      final next = {
        ...payload,
        'seq': (payload['seq']! as int) + 1,
        'data': '',
      };
      final count = 8192 - utf8.encode(jsonEncode(next)).length;
      await a.room.send('boundary', 'x' * count);
      final before = hub.sent.length;
      await expectLater(
        a.room.send('boundary', 'x' * (count + 1)),
        throwsA(
          isA<KitError>().having((e) => e.code, 'code', 'payload_too_large'),
        ),
      );
      expect(hub.sent, hasLength(before));
    },
  );
}
