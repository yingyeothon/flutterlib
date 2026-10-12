@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_game_kit/yingyeothon_game_kit.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

String token(String id) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': id, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600}))).replaceAll('=', '')}.fixture';
Future<T> soon<T>(Future<T> future) =>
    future.timeout(const Duration(seconds: 8));

final class Messaging implements PushMessaging {
  final refresh = StreamController<String>.broadcast();
  final delivery = StreamController<PushMessage>.broadcast();
  final List<String> topics = [];
  @override
  Future<String?> getToken() async => 'fake-device';
  @override
  Stream<String> get tokenRefreshed => refresh.stream;
  @override
  Stream<PushMessage> get messages => delivery.stream;
  @override
  Future<void> subscribe(String topic) async {
    topics.add('+$topic');
  }

  @override
  Future<void> unsubscribe(String topic) async {
    topics.add('-$topic');
  }

  Future<void> close() async {
    await refresh.close();
    await delivery.close();
  }
}

void main() {
  late FakeGateway gateway;
  late FakeMatchServer match;
  final kits = <GameKit>[];
  final aId = 'a' * 32, bId = 'b' * 32;
  setUp(() async {
    gateway = await FakeGateway.start(
      options: FakeGatewayOptions(
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000000),
        kvCollections: const [
          FakeKvCollection(name: 'save', readScope: 'user', writeScope: 'user'),
          FakeKvCollection(
            name: 'content',
            readScope: 'project',
            writeScope: 'team',
            entries: {
              'tuning': {'speed': 2},
            },
          ),
          FakeKvCollection(
            name: 'mail',
            readScope: 'user',
            writeScope: 'project',
          ),
        ],
        leaderboards: const [
          FakeLeaderboard(name: 'weekly', periods: ['alltime', 'weekly']),
          FakeLeaderboard(name: 'server', submit: 'server'),
        ],
        socialProfiles: [
          FakeSocialProfile(owner: aId, displayName: 'Alice'),
          FakeSocialProfile(owner: bId, displayName: 'Bob'),
        ],
      ),
    );
    match = await FakeMatchServer.start();
  });
  tearDown(() async {
    for (final kit in kits.reversed) {
      await soon(kit.close());
    }
    kits.clear();
    await soon(match.shutdown());
    await soon(gateway.shutdown());
  });
  Future<GameKit> create(
    String user, {
    bool deferred = false,
    Messaging? messaging,
  }) async {
    final kit = GameKit(
      GameKitOptions(
        config: GameKitConfig({
          'auth': {'channelId': 'auth_demo'},
          'state': {'url': gateway.wsUrl.replace(scheme: 'http').toString()},
          'gateway': {
            'url': gateway.wsUrl.toString(),
            'lobbyChannelId': 'lobby_demo',
          },
          'collections': {'save': 'save', 'content': 'content', 'mail': 'mail'},
          'boards': {'weekly': 'weekly', 'server': 'server'},
          'match': deferred
              ? {
                  'mode': 'deferred',
                  'apiBase': match.httpUrl.toString(),
                  'ticketUrl': match.httpUrl
                      .resolve('/m/deferred/ticket')
                      .toString(),
                  'channelId': 'deferred',
                }
              : {'url': match.wsUrl.toString(), 'channelId': 'live'},
          'push': {
            'channelId': 'push_demo',
            'apiBase': gateway.wsUrl.replace(scheme: 'http').toString(),
            'topic': 'configured.topic',
          },
        }),
        pushMessaging: messaging,
        firebaseProject: 'demo-project',
      ),
    );
    kits.add(kit);
    await soon(kit.session.fromToken(token(user)));
    return kit;
  }

  Future<void> room(GameKit a, GameKit b) async {
    final subscription = b.room.invited.listen(
      (invite) => unawaited(invite.accept()),
    );
    addTearDown(subscription.cancel);
    await soon(a.room.create());
    final joined = b.room.memberJoined.firstWhere(
      (member) => member.userId == bId,
    );
    await soon(a.room.invite(bId));
    await soon(joined);
  }

  test(
    'scenario 1 clock and 2 conditional save, merge, claim and counter',
    () async {
      final a = await create(aId), b = await create(aId);
      expect(
        a.session.now(),
        closeTo(DateTime.now().millisecondsSinceEpoch, 5000),
      );
      expect(await a.content.get('tuning'), {'speed': 2});
      expect((await a.content.list())['tuning'], {'speed': 2});
      expect(await a.save.load('score'), null);
      expect(await b.save.load('score'), null);
      await a.save.store('score', 1);
      await expectLater(
        b.save.store('score', 2),
        throwsA(isA<KitError>().having((e) => e.code, 'code', 'conflict')),
      );
      await b.save.store(
        'score',
        2,
        merge: (local, remote) => (local as int) + (remote as int),
      );
      expect(await a.save.load('score'), 3);
      expect(await a.save.claimOnce('daily', 10), true);
      expect(await b.save.claimOnce('daily', 10), false);
      expect(await a.save.counter('coins').add(2, min: 0), 2);
      await expectLater(
        a.save.counter('coins').add(-3, min: 0),
        throwsA(isA<KitError>().having((e) => e.code, 'code', 'out_of_range')),
      );
    },
  );
  test(
    'scenario 3 room host authority, state, byte cap and host replacement',
    () async {
      final a = await create(aId), b = await create(bId);
      await room(a, b);
      expect(a.room.members, hasLength(2));
      expect(b.room.host, aId);
      final state = b.room.state.first;
      await a.room.publish({'hp': 7});
      expect(await soon(state), {'hp': 7});
      await expectLater(
        a.room.send('huge', 'x' * 8193),
        throwsA(
          isA<KitError>().having((e) => e.code, 'code', 'payload_too_large'),
        ),
      );
      final hosted = b.room.becameHost.first;
      await a.room.leave();
      expect(await soon(hosted), {'hp': 7});
      expect(b.room.isHost, true);
    },
  );
  test(
    'scenario 4 turns converge, finish persists own result and replay restores',
    () async {
      final a = await create(aId), b = await create(bId);
      await room(a, b);
      Object? apply(Object? state, Object? move, String by) =>
          (state as int) + (move as int);
      final ga = await soon(
        a.turns.start(
          initial: 0,
          apply: apply,
          persist: true,
          saveResultAs: 'result',
        ),
      );
      final gb = await soon(
        b.turns.start(
          initial: 0,
          apply: apply,
          persist: true,
          saveResultAs: 'result',
        ),
      );
      final bTurn = gb.turned.first;
      await soon(ga.submit(1));
      await soon(bTurn);
      final aTurn = ga.turned.first;
      await soon(gb.submit(2));
      await soon(aTurn);
      expect(ga.state, 3);
      expect(gb.state, 3);
      expect(ga.index, 2);
      await soon(ga.finish({'won': aId}));
      await soon(gb.resync());
      expect(
        (await soon(a.save.load('result'))) as Map,
        containsPair('finalHash', isA<String>()),
      );
      expect(gb.state, 3);
    },
  );
  test('scenario 5 board and 6 mail exactly one claim and arrival', () async {
    final a = await create(aId),
        b = await create(bId),
        secondB = await create(bId);
    final submissions = await a.board('weekly').submit(10);
    expect(submissions, hasLength(2));
    expect((await a.board('weekly').around('alltime')).first.rank, 1);
    await expectLater(
      a.board('server').submit(1),
      throwsA(isA<KitError>().having((e) => e.code, 'code', 'server_only')),
    );
    final arrived = b.mail.arrived.first;
    await a.mail.send(bId, {'reward': 5});
    // Foreground transition forces a poll without waiting the production interval.
    b.setForeground(false);
    b.setForeground(true);
    final letter = await soon(arrived);
    final outcomes = await Future.wait([
      b.mail.claim(letter.id).then<Object?>((v) => v, onError: (Object e) => e),
      secondB.mail
          .claim(letter.id)
          .then<Object?>((v) => v, onError: (Object e) => e),
    ]);
    expect(outcomes.whereType<KitLetter>(), hasLength(1));
    expect(outcomes.whereType<KitError>().single.code, 'already_claimed');
  });
  test('scenario 7 friend relation and presence join', () async {
    final a = await create(aId), b = await create(bId);
    await room(a, b);
    await a.friends.request(bId);
    expect((await b.friends.requests()).incoming, [aId]);
    await b.friends.accept(aId);
    final friends = await a.friends.list();
    expect(friends.single.userId, bId);
    expect(friends.single.online, true);
    await b.friends.block(aId);
    await expectLater(a.friends.request(bId), throwsA(isA<KitError>()));
    expect((await a.friends.requests()).incoming, isEmpty);
  });
  test('scenario 9 deferred all accept same members, 10 push wakes and signout cleanup', () async {
    final messaging = Messaging();
    addTearDown(messaging.close);
    final a = await create(aId, deferred: true, messaging: messaging),
        b = await create(bId, deferred: true);
    await a.push.start();
    expect(messaging.topics, ['+configured.topic']);
    await soon(a.matchmaking.submit());
    await soon(b.matchmaking.submit());
    expect((await soon(a.matchmaking.status()))!.state, 'proposed');
    await soon(a.matchmaking.accept());
    await soon(b.matchmaking.accept());
    expect((await soon(a.matchmaking.status()))!.match!.members, [aId, bId]);
    final wake = a.push.received.first;
    messaging.delivery.add(
      PushMessage(
        data: {'channelId': 'deferred', 'matchId': 'm', 'state': 'confirmed'},
      ),
    );
    expect((await soon(wake)).matchWake, true);
    await a.push.unregister();
    expect(messaging.topics, ['+configured.topic', '-configured.topic']);
    expect(gateway.push.tokenCount, 0);
  });
}
