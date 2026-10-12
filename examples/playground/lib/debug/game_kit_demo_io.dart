import 'dart:async';
import 'dart:convert';

import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_game_kit/yingyeothon_game_kit.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

String _jwt(String user) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': user, 'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600}))).replaceAll('=', '')}.offline';
Future<T> _soon<T>(Future<T> task) => task.timeout(const Duration(seconds: 20));

final class _Messaging implements PushMessaging {
  final _refresh = StreamController<String>.broadcast();
  final delivery = StreamController<PushMessage>.broadcast();
  @override
  Future<String?> getToken() async => 'offline-device';
  @override
  Stream<String> get tokenRefreshed => _refresh.stream;
  @override
  Stream<PushMessage> get messages => delivery.stream;
  @override
  Future<void> subscribe(String topic) async {}
  @override
  Future<void> unsubscribe(String topic) async {}
  Future<void> close() async {
    await _refresh.close();
    await delivery.close();
  }
}

/// Walks every kit wave over loopback fakes, with no credentials or Firebase.
Future<List<String>> runGameKitDemo() async {
  final users = [
    for (final character in ['a', 'b', 'c', 'd']) character * 32,
  ];
  final gateway = await FakeGateway.start(
    options: FakeGatewayOptions(
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
      ],
      socialProfiles: [
        for (var n = 0; n < users.length; n++)
          FakeSocialProfile(owner: users[n], displayName: 'Player ${n + 1}'),
      ],
    ),
  );
  final match = await FakeMatchServer.start(partySize: 4);
  final messaging = _Messaging();
  final kits = <GameKit>[];
  final failures = <KitError>[];
  final refused = <StreamSubscription<KitError>>[];
  GameKitConfig config(bool deferred) => GameKitConfig({
    'auth': {'channelId': 'auth_demo'},
    'state': {'url': gateway.wsUrl.replace(scheme: 'http').toString()},
    'gateway': {
      'url': gateway.wsUrl.toString(),
      'lobbyChannelId': 'lobby_demo',
    },
    'collections': {'save': 'save', 'content': 'content', 'mail': 'mail'},
    'boards': {'weekly': 'weekly'},
    'match': deferred
        ? {
            'mode': 'deferred',
            'apiBase': match.httpUrl.toString(),
            'ticketUrl': match.httpUrl.resolve('/m/deferred/ticket').toString(),
            'channelId': 'deferred',
          }
        : {'url': match.wsUrl.toString(), 'channelId': 'live'},
    'push': {
      'channelId': 'push_demo',
      'apiBase': gateway.wsUrl.replace(scheme: 'http').toString(),
      'topic': 'configured.topic',
    },
  });
  Future<GameKit> create(String user, {bool deferred = false}) async {
    final kit = GameKit(
      GameKitOptions(
        config: config(deferred),
        pushMessaging: deferred && user == users.first ? messaging : null,
        firebaseProject: 'demo-project',
      ),
    );
    kits.add(kit);
    refused.add(kit.refused.listen(failures.add));
    await _soon(kit.session.fromToken(_jwt(user)));
    return kit;
  }

  try {
    final players = <GameKit>[];
    for (final user in users) {
      players.add(await create(user));
    }
    final a = players[0], b = players[1];
    await a.content.get('tuning');
    await a.save.load('progress');
    await a.save.store('progress', {'level': 1});
    final once = await a.save.claimOnce('daily', 60);
    await a.save.counter('coins').add(5, min: 0);
    await a.board('weekly').submit(10);
    await a.mail.send(users[1], {'reward': 5});
    final letter = (await b.mail.list()).single;
    await b.mail.claim(letter.id);
    await a.friends.request(users[1]);
    await b.friends.accept(users[0]);
    await Future.wait(players.map((p) => p.room.connect()));
    final formed = await _soon(
      Future.wait(players.map((p) => p.matchmaking.find())),
    );
    final snapshot = b.room.state.first;
    await a.room.publish({'hp': 7});
    await _soon(snapshot);
    Object? apply(Object? state, Object? move, String by) =>
        (state as int) + (move as int);
    final games = <KitTurnGame>[];
    for (final player in players) {
      games.add(
        await _soon(
          player.turns.start(
            initial: 0,
            apply: apply,
            persist: true,
            saveResultAs: 'last-result',
          ),
        ),
      );
    }
    for (var n = 0; n < games.length; n++) {
      final observer = games[(n + 1) % games.length].turned.first;
      await _soon(games[n].submit(n + 1));
      await _soon(observer);
    }
    await _soon(games[0].finish({'score': 10}));
    if (games.any((g) => g.state != 10 || g.index != 4)) {
      throw StateError('turn convergence failed');
    }
    final becameHost = b.room.becameHost.first;
    await a.room.leave();
    await _soon(becameHost);
    final deferred = <GameKit>[];
    for (final user in users) {
      deferred.add(await create(user, deferred: true));
    }
    await deferred.first.push.start();
    await _soon(Future.wait(deferred.map((p) => p.matchmaking.submit())));
    KitMatchStatus? confirmed;
    for (final player in deferred) {
      confirmed = await _soon(player.matchmaking.accept());
    }
    final wake = deferred.first.push.received.first;
    messaging.delivery.add(
      PushMessage(
        data: {
          'channelId': 'deferred',
          'matchId': confirmed!.match!.matchId,
          'state': 'confirmed',
        },
      ),
    );
    await _soon(wake);
    await deferred.first.session.signOut();
    await _soon(deferred.first.close());
    if (failures.isNotEmpty) {
      throw StateError(
        'Kit refused: ${failures.first.module}/${failures.first.code}',
      );
    }
    return [
      'Kit session: server clock synchronized',
      'Kit save: conditional store, counter, daily claim $once',
      'Kit live match: ${formed.first.members.length} members in one room',
      'Kit room: state and host handoff verified',
      'Kit turns: 4 moves, final state 10',
      'Kit board, mail and friends: verified',
      'Kit deferred match: ${confirmed.state}',
      'Kit push: wake received, ${gateway.push.tokenCount} tokens after sign-out',
    ];
  } finally {
    for (final kit in kits.reversed) {
      await _soon(kit.close());
    }
    for (final subscription in refused) {
      await subscription.cancel();
    }
    await messaging.close();
    await _soon(match.shutdown());
    await _soon(gateway.shutdown());
  }
}
