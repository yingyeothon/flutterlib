@Tags(['integration'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../support/harness.dart';

Future<T> soon<T>(Future<T> f) => f.timeout(const Duration(seconds: 5));

void main() {
  late FakeGateway gw;
  setUp(
    () async => gw = await FakeGateway.start(
      options: const FakeGatewayOptions(tick: 30),
    ),
  );
  tearDown(() => gw.shutdown());

  GatewayLobbyClientOptions lobbyOptions(
    String token,
    CapturingLogWriter log,
  ) => GatewayLobbyClientOptions(
    url: gw.wsUrl.toString(),
    channelId: 'lobby_0123456789abcdef',
    token: token,
    logger: createFilteredLogger(severity: LogSeverity.debug, writer: log),
    backoff: const BackoffOptions(initialMs: 50, jitter: 0),
  );

  test('two lobby clients see each other move and chat; map fetches', () async {
    final log = CapturingLogWriter();
    final alice = GatewayLobbyClient(lobbyOptions('alice', log));
    final bob = GatewayLobbyClient(lobbyOptions('bob', log));
    addTearDown(alice.close);
    addTearDown(bob.close);

    final hello = await soon(alice.connect());
    expect(hello.userId, 'alice');
    expect(hello.zone, 'Zone001');
    await soon(bob.connect());

    final aliceSnapshot = alice.snapshots.first;
    alice.pos(zone: 'Zone001', x: 1, y: 2, dir: 'n');
    await soon(aliceSnapshot);
    expect(alice.peers.all(), isEmpty, reason: 'self is not a peer');

    final bobEnters = alice.peerEntered.first;
    bob.pos(zone: 'Zone001', x: 3, y: 4);
    final entered = await soon(bobEnters);
    expect(entered.userId, 'bob');
    expect(alice.peers.all().map((p) => p.userId), ['bob']);

    final moved = alice.peerMoved.first;
    bob.pos(zone: 'Zone001', x: 5, y: 6);
    expect((await soon(moved)).single.x, 5);
    expect(alice.peers.get('bob')!.y, 6);

    final heard = bob.said.first;
    alice.say(scope: SayScope.zone, text: 'hello bob');
    final said = await soon(heard);
    expect(said.from, 'alice');
    expect(said.text, 'hello bob');

    final map = await soon(alice.map());
    expect(map, {
      'name': 'fake',
      'zones': ['Zone001', 'Zone002'],
    });

    final refused = alice.refused.first;
    alice.say(scope: SayScope.user, to: 'nobody', text: 'x');
    expect((await soon(refused)).code, GatewayErrorCode.unknownUser);

    final all = log.lines.join('\n');
    expect(all, contains('lobby connected'));
    expect(
      all,
      isNot(contains('alice\n')),
      reason: 'no token, even a plain one, as a bare line',
    );
    expect(all, isNot(contains('bearer')));
  });

  test('parties across two clients', () async {
    final log = CapturingLogWriter();
    final alice = GatewayLobbyClient(lobbyOptions('alice', log));
    final bob = GatewayLobbyClient(lobbyOptions('bob', log));
    addTearDown(alice.close);
    addTearDown(bob.close);
    await soon(alice.connect());
    await soon(bob.connect());

    final created = alice.partyChanged.first;
    alice.party.create();
    final roster = await soon(created);
    expect(alice.partyId, roster.partyId);
    expect(roster.leaderId, 'alice');
    expect(roster.invited, isEmpty);

    final invited = bob.partyInvited.first;
    alice.party.invite('bob');
    final invite = await soon(invited);
    expect(invite.from, 'alice');

    final joined = bob.partyChanged.first;
    bob.party.accept(invite.partyId);
    final joinedRoster = await soon(joined);
    expect(joinedRoster.members.map((m) => m.userId), ['alice', 'bob']);
    expect(bob.partyId, invite.partyId);

    final left = bob.partyChanged
        .skip(0)
        .firstWhere((f) => f.leaderId == 'bob');
    alice.party.leave();
    expect((await soon(left)).members.map((m) => m.userId), ['bob']);
    expect(alice.partyId, isNull);
  });

  test('a gateway close reconnects and the client re-enters', () async {
    final log = CapturingLogWriter();
    final alice = GatewayLobbyClient(lobbyOptions('alice', log));
    addTearDown(alice.close);
    final trace = <String>[];
    alice.disconnected.listen(
      (e) => trace.add('disconnected:${e.code}:${e.willReconnect}'),
    );
    alice.reconnecting.listen((e) => trace.add('reconnecting:${e.attempt}'));
    alice.connected.listen((h) => trace.add('connected'));
    await soon(alice.connect());
    alice.pos(zone: 'Z', x: 0, y: 0);
    await soon(alice.snapshots.first);

    final reconnected = alice.connected.first;
    await gw.closeUser('alice', 4002, reason: 'idle');
    await soon(reconnected);
    // The fake retains the zone and re-sends the snapshot after hello.
    final snapshot = await soon(alice.snapshots.first);
    expect(snapshot.zone, 'Z');
    expect(trace, [
      'connected',
      'disconnected:4002:true',
      'reconnecting:1',
      'connected',
    ]);
    expect(alice.state, GatewayClientState.connected);
  });

  test('a rejected token stops after maxHandshakeFailures without a token in the log', () async {
    final strict = await FakeGateway.start(
      options: const FakeGatewayOptions(acceptedTokens: {'good'}),
    );
    addTearDown(strict.shutdown);
    final log = CapturingLogWriter();
    final client = GatewayLobbyClient(
      GatewayLobbyClientOptions(
        url: strict.wsUrl.toString(),
        channelId: 'lobby_0123456789abcdef',
        token: fixtureToken,
        maxHandshakeFailures: 2,
        backoff: const BackoffOptions(initialMs: 20, jitter: 0),
        logger: createFilteredLogger(severity: LogSeverity.debug, writer: log),
      ),
    );
    addTearDown(client.close);
    final stopped = client.stopped.first;
    await expectLater(
      soon(client.connect()),
      throwsA(isA<GatewayStoppedException>()),
    );
    final event = await soon(stopped);
    expect(event.kind, CloseDispositionKind.stop);
    expect(event.reason, 'handshake failed 2 times in a row');
    expect(log.lines.join('\n'), isNot(contains('secret-token')));
  });

  test('q: connect, echo, abort with 4001', () async {
    final log = CapturingLogWriter();
    final client = GatewayGameClient(
      GatewayGameClientOptions(
        url: gw.wsUrl.toString(),
        channelId: 'q_0123456789abcdef',
        gameId: 'g1',
        token: 'alice',
        logger: createFilteredLogger(severity: LogSeverity.debug, writer: log),
      ),
    );
    addTearDown(client.close);
    final frames = <Object?>[];
    client.frames.listen(frames.add);
    final welcome = client.frames.first;
    await soon(client.connect());
    expect(((await soon(welcome)) as Map)['type'], 'welcome');
    final echo = client.frames.first;
    client.send({'type': 'move', 'dx': 1});
    expect(await soon(echo), {
      'type': 'echo',
      'of': {'type': 'move', 'dx': 1},
    });
    expect(frames, hasLength(2));
    final aborted = client.aborted.first;
    await gw.closeUser('alice', 4001, gameId: 'g1');
    expect((await soon(aborted)).code, 4001);
    expect(client.state, GatewayClientState.closed);
  });

  test('q: a normal finish is 1000', () async {
    final client = GatewayGameClient(
      GatewayGameClientOptions(
        url: gw.wsUrl.toString(),
        channelId: 'q_0123456789abcdef',
        gameId: 'g2',
        token: 'bob',
      ),
    );
    addTearDown(client.close);
    await soon(client.connect());
    final finished = client.finished.first;
    await gw.closeUser('bob', 1000, gameId: 'g2');
    expect((await soon(finished)).code, 1000);
  });
}
