// Drives the lobby screen against the in-process fake gateway over the real
// transport. `tester.runAsync` lets real sockets progress inside a widget
// test; `pumpUntil` polls the tree until a condition holds.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
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
    gw = await FakeGateway.start(options: const FakeGatewayOptions(tick: 30));
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

  testWidgets('chat sends a zone say and shows it back', (tester) async {
    await openLobby(tester);
    await tester.tap(find.byKey(const Key('tab-chat')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-text')), 'hello zone');
    await tester.tap(find.byKey(const Key('chat-send')));
    await pumpUntil(tester, () => session.chat.isNotEmpty);
    expect(find.text('you (zone): hello zone'), findsOneWidget);
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
