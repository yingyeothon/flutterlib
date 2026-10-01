// Drives the leaderboard screen against the in-process fake gateway's /lb
// routes over the real http client. `tester.runAsync` lets real sockets
// progress inside a widget test; `pumpUntil` polls the tree.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yyt_playground/config.dart';
import 'package:yyt_playground/main.dart';
import 'package:yyt_playground/screens/leaderboard_screen.dart';
import 'package:yyt_playground/session.dart';

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met');
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
    // flutter_test answers every HttpClient with an empty 400; the client
    // talks to the fake over a real socket (this file is its own isolate).
    HttpOverrides.global = null;
    gw = await FakeGateway.start(
      options: const FakeGatewayOptions(
        leaderboards: <FakeLeaderboard>[
          FakeLeaderboard(
            name: 'race',
            periods: <String>['alltime', 'weekly'],
            scores: <String, int>{'seed-1': 80, 'seed-2': 60},
          ),
        ],
      ),
    );
    session = Session(
      config: PlaygroundConfig(
        gatewayUrl: '',
        channelId: '',
        authBaseUrl: '',
        authChannelId: '',
        kvBaseUrl: gw.kvUrl.toString(),
      ),
    );
    session.token = const ChannelToken(jwt: 'you', userId: 'you', exp: 0);
  });

  tearDown(() async {
    session.dispose();
    await gw.shutdown();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(PlaygroundApp(session: session));
    });
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed(LeaderboardScreen.route);
    await pumpUntil(
      tester,
      () => session.log.any((l) => l.text.startsWith('leaderboard: ')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the page, then my row after a submission', (tester) async {
    await open(tester);
    expect(
      find.text('submit owner, rule best, order desc, periods alltime/weekly'),
      findsOneWidget,
    );
    expect(find.text('alltime · 2 row(s)'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('seed-1'), findsOneWidget);
    expect(find.text('No row of mine yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('mine-submit')));
    await pumpUntil(tester, () => session.myScore != null);
    await tester.pumpAndSettle();
    expect(find.text('Stored 70, rank 2 of 3'), findsOneWidget);
    expect(find.text('alltime · 3 row(s)'), findsOneWidget);
    expect(gw.lb.scoreOf('race', 'you'), 70);
    expect(gw.lb.scoreOf('race', 'you', period: 'weekly'), 70);

    // A worse score on a best board changes nothing.
    await tester.enterText(find.byKey(const Key('mine-score')), '10');
    await tester.tap(find.byKey(const Key('mine-submit')));
    await pumpUntil(
      tester,
      () =>
          session.log
              .where((l) => l.text == 'leaderboard: 3 rows, my rank 2')
              .length ==
          2,
    );
    await tester.pumpAndSettle();
    expect(find.text('Stored 70, rank 2 of 3'), findsOneWidget);
    expect(
      session.log.map((l) => l.text),
      contains('leaderboard: submitted 10, stored 70/70 over 2 bucket(s)'),
    );
    // The log names kinds and counts, never the token; the 200 on a route
    // that needs the bearer is the positive control that it went out.
    final log = session.log.map((l) => l.text).join('\n');
    expect(log, contains('"route":"score","status":200'));
    expect(log, isNot(contains('Bearer')));
  });

  testWidgets('a non-integer score is refused in place', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('mine-score')), 'x');
    await tester.tap(find.byKey(const Key('mine-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('score must be an integer'), findsOneWidget);
    expect(gw.lb.scoreOf('race', 'you'), isNull);
  });

  testWidgets('Back pops the screen and closes the client quietly', (
    tester,
  ) async {
    await open(tester);
    expect(session.lb, isNotNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(session.lb, isNull);
    expect(tester.takeException(), isNull);
  });
}
