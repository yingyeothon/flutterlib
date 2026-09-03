import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yyt_playground/config.dart';
import 'package:yyt_playground/main.dart';
import 'package:yyt_playground/screens/dungeon_screen.dart';
import 'package:yyt_playground/session.dart';

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
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
    gw = await FakeGateway.start();
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

  Future<void> openAndConnect(WidgetTester tester) async {
    await tester.runAsync(
      () => tester.pumpWidget(PlaygroundApp(session: session)),
    );
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed(DungeonScreen.route);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'q channel id (from the console)'),
      'q_test',
    );
    await tester.tap(find.byKey(const Key('q-connect')));
    await pumpUntil(tester, () => session.gameFrames.isNotEmpty);
  }

  testWidgets('connects, receives the welcome, echoes a frame', (tester) async {
    await openAndConnect(tester);
    expect(find.textContaining('"type":"welcome"'), findsOneWidget);
    await tester.tap(find.byKey(const Key('q-send')));
    await pumpUntil(tester, () => session.gameFrames.length == 2);
    expect(find.textContaining('"type":"echo"'), findsOneWidget);
  });

  testWidgets('4001 shows the Aborted banner', (tester) async {
    await openAndConnect(tester);
    await tester.runAsync(() => gw.closeUser('you', 4001, gameId: 'g_demo'));
    await pumpUntil(tester, () => session.gameEnded != null);
    expect(find.textContaining('Aborted (4001)'), findsOneWidget);
  });

  testWidgets('1000 shows the Finished banner', (tester) async {
    await openAndConnect(tester);
    await tester.runAsync(() => gw.closeUser('you', 1000, gameId: 'g_demo'));
    await pumpUntil(tester, () => session.gameEnded != null);
    expect(find.textContaining('Finished (1000)'), findsOneWidget);
  });
}
