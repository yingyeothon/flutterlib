// Drives the lobby screen against the in-process fake gateway over the real
// transport. `tester.runAsync` lets real sockets progress inside a widget
// test; `pumpUntil` polls the tree until a condition holds.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yyt_playground/config.dart';
import 'package:yyt_playground/main.dart';
import 'package:yyt_playground/screens/lobby_screen.dart';
import 'package:yyt_playground/session.dart';

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    // Real time for the sockets, then fake time for the SDK's timers (the
    // reconnect backoff is a Timer created in the test zone).
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  late FakeGateway gw;
  late Session session;

  setUp(() async {
    gw = await FakeGateway.start(
      options: const FakeGatewayOptions(
        tick: 30,
        mapDocument: <String, Object?>{
          'name': 'arena',
          'width': 16,
          'height': 12,
          'zones': <Object?>['Zone001', 'Zone002', 'Zone003'],
          'blocked': <Object?>[
            <Object?>[5, 4],
          ],
        },
      ),
    );
    session = Session(
      config: PlaygroundConfig(
        gatewayUrl: gw.wsUrl.toString(),
        channelId: 'lobby_test',
        authBaseUrl: '',
        authChannelId: '',
      ),
    );
    session.token = const ChannelToken(jwt: 'you', userId: 'you', exp: 0);
  });

  tearDown(() async {
    session.dispose();
    await gw.shutdown();
  });

  Future<void> openLobby(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(PlaygroundApp(session: session));
    });
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pushNamed(LobbyScreen.route);
    await pumpUntil(tester, () => session.lobby?.hello != null);
    await pumpUntil(tester, () => session.lobby?.peers.zone != null);
    // Moves are held until the gateway settles the resume position.
    await pumpUntil(tester, () => !session.placing);
    // Let the route transition finish before tapping anything on the page.
    await tester.pumpAndSettle();
  }

  testWidgets('connects, enters the zone and shows a peer that joins', (
    tester,
  ) async {
    await openLobby(tester);
    expect(find.textContaining('Lobby · connected'), findsOneWidget);
    expect(find.text('0 peer(s) in view'), findsOneWidget);

    late WebSocket other;
    await tester.runAsync(() async {
      other = await WebSocket.connect(
        gw.wsUrl.replace(queryParameters: {'channel': 'lobby_test'}).toString(),
        protocols: ['bearer', 'other'],
      );
      other.listen((_) {});
      other.add(
        Json.encode({'type': 'pos', 'zone': 'Zone001', 'x': 2, 'y': 3}),
      );
    });
    await pumpUntil(tester, () => session.lobby!.peers.all().length == 1);
    expect(find.text('1 peer(s) in view'), findsOneWidget);

    await tester.tap(find.byKey(const Key('move-right')));
    await pumpUntil(
      tester,
      () => gw.received('you').where((f) => f['type'] == 'pos').length >= 2,
    );
    final last = gw.received('you').lastWhere((f) => f['type'] == 'pos');
    expect(last['x'], 6.0);
    expect(last['dir'], 'e');

    await tester.runAsync(() => other.close());
    await pumpUntil(tester, () => session.lobby!.peers.all().isEmpty);
    expect(find.text('0 peer(s) in view'), findsOneWidget);
  });

  testWidgets('the zone tab draws the fetched map: size, zones and walls', (
    tester,
  ) async {
    // flutter_test answers every HttpClient request with an empty 400, which
    // the other tests rely on (a failed map fetch leaves no timer); this one
    // fetches the map from the fake for real.
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    await openLobby(tester);
    await pumpUntil(tester, () => session.mapLayout.name == 'arena');
    expect(find.text('Map arena · 16×12'), findsOneWidget);
    expect(
      session.log.map((l) => l.text),
      contains('map loaded: 16x12, 3 zone(s), 1 blocked'),
    );

    int posCount() =>
        gw.received('you').where((f) => f['type'] == 'pos').length;
    final sent = posCount();
    // (5, 4) is a wall in the map: the move is the game's to refuse.
    await tester.tap(find.byKey(const Key('move-up')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    expect(posCount(), sent);
    // Positive control: the same button path sends an open move.
    await tester.tap(find.byKey(const Key('move-down')));
    await pumpUntil(tester, () => posCount() == sent + 1);
    expect(gw.received('you').last['y'], 6.0);

    await tester.tap(find.byKey(const Key('zone-chip-Zone003')));
    await pumpUntil(tester, () => session.lobby!.peers.zone == 'Zone003');
    final last = gw.received('you').lastWhere((f) => f['type'] == 'pos');
    expect(last['zone'], 'Zone003');
    // The map fetch left one pooled keep-alive connection, whose idle timer
    // runs on the test clock; let it expire, or the binding reports it.
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('a reconnect resumes from the position the app last sent', (
    tester,
  ) async {
    // The gateway's default delta: a fixed spawn point would be refused.
    await tester.runAsync(() async {
      await gw.shutdown();
      gw = await FakeGateway.start(
        options: const FakeGatewayOptions(tick: 30, maxMoveDelta: 3),
      );
    });
    session.config = session.config.copyWith(gatewayUrl: gw.wsUrl.toString());
    await openLobby(tester);
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const Key('move-right')));
      await tester.pump();
    }
    await pumpUntil(tester, () => gw.received('you').last['x'] == 11.0);
    await tester.runAsync(() => gw.closeUser('you', 4002));
    await pumpUntil(
      tester,
      () => gw.received('you').where((f) => f['type'] == 'pos').length >= 8,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    // The resume announced (11, 5), within the delta of what the fake kept;
    // (5, 5) would have been refused as move_too_far.
    expect(gw.received('you').last['x'], 11.0);
    expect(
      session.log.map((l) => l.text),
      isNot(contains('refused: move_too_far')),
    );
  });

  testWidgets(
    'with nothing kept, a restored position in the zone sent is adopted',
    (tester) async {
      await tester.runAsync(() async {
        await gw.shutdown();
        gw = await FakeGateway.start(
          options: const FakeGatewayOptions(tick: 30, maxMoveDelta: 3),
        );
        // An earlier run of the app left `you` at (15, 15) in Zone001.
        final earlier = await WebSocket.connect(
          gw.wsUrl
              .replace(queryParameters: {'channel': 'lobby_test'})
              .toString(),
          protocols: ['bearer', 'you'],
        );
        earlier.listen((_) {});
        earlier.add(
          Json.encode({'type': 'pos', 'zone': 'Zone001', 'x': 15, 'y': 15}),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await earlier.close();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      session.config = session.config.copyWith(gatewayUrl: gw.wsUrl.toString());
      await openLobby(tester);
      // The spawn point (5, 5) is a jump from the restored (15, 15)...
      await pumpUntil(
        tester,
        () => session.log.any((l) => l.text == 'refused: move_too_far'),
      );
      // ...and the first batch for that zone says where the gateway has you.
      await pumpUntil(tester, () => session.position?.x == 15.0);
      expect(session.position?.y, 15.0);
      await tester.tap(find.byKey(const Key('move-left')));
      await pumpUntil(tester, () => gw.received('you').last['x'] == 14.0);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(
        session.log.where((l) => l.text == 'refused: move_too_far'),
        hasLength(1),
        reason: 'the step from the adopted position lands',
      );
    },
  );

  testWidgets('a kept position belongs to one user', (tester) async {
    await openLobby(tester);
    await tester.tap(find.byKey(const Key('move-right')));
    await pumpUntil(tester, () => session.position?.x == 6.0);
    await tester.runAsync(session.closeLobby);
    session.token = const ChannelToken(jwt: 'other', userId: 'other', exp: 0);
    await tester.runAsync(session.connectLobby);
    await pumpUntil(
      tester,
      () => gw.received('other').any((f) => f['type'] == 'pos'),
    );
    final first = gw.received('other').firstWhere((f) => f['type'] == 'pos');
    expect((first['x'], first['y']), (5.0, 5.0));
  });

  testWidgets('chat sends a zone say and shows it back', (tester) async {
    await openLobby(tester);
    await tester.tap(find.byKey(const Key('tab-chat')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-text')), 'hello zone');
    await tester.tap(find.byKey(const Key('chat-send')));
    await pumpUntil(tester, () => session.chat.isNotEmpty);
    expect(find.text('you (zone): hello zone'), findsOneWidget);
  });

  testWidgets('a whisper without "to" is refused in place', (tester) async {
    await openLobby(tester);
    await tester.tap(find.byKey(const Key('tab-chat')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<SayScope>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('user').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-text')), 'psst');
    await tester.tap(find.byKey(const Key('chat-send')));
    await tester.pump();
    expect(
      find.text('FormatException: a whisper needs a user id in "to"'),
      findsOneWidget,
    );
    expect(session.chat, isEmpty);
  });

  testWidgets('a party is created and the roster is shown', (tester) async {
    await openLobby(tester);
    await tester.tap(find.byKey(const Key('tab-party')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('party-create')));
    await pumpUntil(tester, () => session.lobby!.partyId != null);
    expect(find.textContaining('Party pty_'), findsOneWidget);
    expect(find.text('• you'), findsOneWidget);
  });

  testWidgets('a forced 4002 shows the reconnect banner, then clears', (
    tester,
  ) async {
    await openLobby(tester);
    await tester.runAsync(() => gw.closeUser('you', 4002));
    await pumpUntil(tester, () => session.lastBanner != null);
    expect(session.lastBanner, 'disconnected (4002): reconnecting');
    expect(find.byKey(const Key('close-banner')), findsOneWidget);
    await pumpUntil(
      tester,
      () => session.lastBanner == null,
      timeout: const Duration(seconds: 10),
    );
    expect(find.textContaining('Lobby · connected'), findsOneWidget);
  });

  testWidgets('a forced 4000 stops for good', (tester) async {
    await openLobby(tester);
    await tester.runAsync(() => gw.closeUser('you', 4000));
    await pumpUntil(
      tester,
      () => (session.lastBanner ?? '').startsWith('stopped'),
    );
    expect(find.textContaining('stopped (4000)'), findsOneWidget);
  });
}
