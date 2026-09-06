// Drives the key-value screen against the in-process fake gateway's /kv
// routes over the real http client. `tester.runAsync` lets real sockets
// progress inside a widget test; `pumpUntil` polls the tree.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yyt_playground/config.dart';
import 'package:yyt_playground/main.dart';
import 'package:yyt_playground/screens/kv_screen.dart';
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
    // flutter_test answers every HttpClient with an empty 400; the store
    // client talks to the fake over a real socket, so lift the override
    // (each test file runs in its own isolate, so nothing else sees this).
    HttpOverrides.global = null;
    gw = await FakeGateway.start(
      options: const FakeGatewayOptions(
        kvCollections: <FakeKvCollection>[
          FakeKvCollection(
            name: 'announcements',
            readScope: 'project',
            writeScope: 'team',
            entries: <String, Object?>{
              '2026-09-01': <String, Object?>{
                'title': 'Welcome',
                'body': 'first',
              },
              '2026-09-06': <String, Object?>{
                'title': 'Season 2',
                'body': 'second',
              },
            },
          ),
          FakeKvCollection(
            name: 'profile',
            readScope: 'user',
            writeScope: 'user',
          ),
        ],
      ),
    );
    session = Session(
      config: PlaygroundConfig(
        gatewayUrl: gw.wsUrl.toString(),
        channelId: 'lobby_test',
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
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(
      () => tester.pumpWidget(PlaygroundApp(session: session)),
    );
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed(KvScreen.route);
    await pumpUntil(
      tester,
      () => session.announcements.isNotEmpty && session.settingsAbsent,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the announcements newest first, read only', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Season 2'), findsOneWidget);
    expect(find.text('Welcome'), findsOneWidget);
    final season = tester.getTopLeft(find.text('Season 2'));
    final welcome = tester.getTopLeft(find.text('Welcome'));
    expect(season.dy, lessThan(welcome.dy), reason: 'desc');
    expect(find.text('2026-09-06 · v1'), findsOneWidget);
    expect(find.text('No settings stored yet'), findsOneWidget);
  });

  testWidgets('saves and reloads my settings through /u/me', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('settings-volume')), '0.25');
    await tester.tap(find.byKey(const Key('settings-save')));
    await pumpUntil(tester, () => session.settings != null);
    await tester.pumpAndSettle();
    expect(find.text('Stored: {"volume":0.25} (version 1)'), findsOneWidget);
    expect(
      gw.kv.valueText('profile', 'settings', owner: 'you'),
      '{"volume":0.25}',
    );
    await tester.enterText(find.byKey(const Key('settings-volume')), '1');
    await tester.tap(find.byKey(const Key('settings-save')));
    await pumpUntil(tester, () => session.settings?.version == 2);
    await tester.pumpAndSettle();
    expect(find.text('Stored: {"volume":1.0} (version 2)'), findsOneWidget);
    expect(find.byKey(const Key('close-banner')), findsNothing);
    expect(
      session.log.any((l) => l.text.contains('settings: updated version 2')),
      isTrue,
    );
    expect(
      session.log.any((l) => l.text.contains('kv request')),
      isTrue,
      reason: 'the SDK logs through the session',
    );
  });

  testWidgets('a refusal shows the code and status, never the token', (
    tester,
  ) async {
    await open(tester);
    // A second listener that refuses this token: the next request is a 401.
    final strict = (await tester.runAsync(
      () => FakeGateway.start(
        options: const FakeGatewayOptions(acceptedTokens: <String>{'other'}),
      ),
    ))!;
    addTearDown(() => tester.runAsync(strict.shutdown));
    session.updateConfig(
      session.config.copyWith(kvBaseUrl: strict.kvUrl.toString()),
    );
    session.closeKv();
    await tester.tap(find.byKey(const Key('settings-load')));
    await pumpUntil(
      tester,
      () => find.byKey(const Key('close-banner')).evaluate().isNotEmpty,
    );
    expect(find.text('refused (401): sign in again'), findsOneWidget);
    // Positive control, then the negative: the SDK logged the refusal and
    // no line carries the bearer.
    expect(session.log.any((l) => l.text.contains('"status":401')), isTrue);
    expect(session.log.every((l) => !l.text.contains('Bearer')), isTrue);
    await tester.enterText(find.byKey(const Key('settings-volume')), 'x');
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(find.text('Bad state: volume must be a number'), findsOneWidget);
  });
}
