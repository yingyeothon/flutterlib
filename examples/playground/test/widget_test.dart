// This file keeps the name `flutter create .` would otherwise fill with the
// counter template; it is the login screen's test.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yyt_playground/config.dart';
import 'package:yyt_playground/main.dart';
import 'package:yyt_playground/session.dart';

void main() {
  testWidgets(
    'the login screen renders the console fields and the demo button',
    (tester) async {
      final session = Session(
        config: const PlaygroundConfig(
          gatewayUrl: '',
          channelId: '',
          authBaseUrl: '',
          authChannelId: '',
        ),
      );
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(PlaygroundApp(session: session));
      expect(find.text('Console values'), findsOneWidget);
      expect(find.text('Not signed in'), findsOneWidget);
      // flutter test runs in debug mode, so the kDebugMode-gated button exists.
      expect(find.byKey(const Key('offline-demo')), findsOneWidget);
      final enter = tester.widget<FilledButton>(
        find.byKey(const Key('enter-lobby')),
      );
      expect(enter.onPressed, isNull, reason: 'disabled until signed in');
      session.dispose();
    },
  );

  testWidgets('a pasted token without an auth channel signs in unverified', (
    tester,
  ) async {
    final session = Session(
      config: const PlaygroundConfig(
        gatewayUrl: 'ws://127.0.0.1:1',
        channelId: 'lobby_x',
        authBaseUrl: '',
        authChannelId: '',
      ),
    );
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(PlaygroundApp(session: session));
    await tester.enterText(
      find.widgetWithText(TextField, 'Or paste a channel JWT'),
      'tok',
    );
    await tester.tap(find.text('Use this token'));
    await tester.pump();
    expect(find.text('Signed in as (unverified)'), findsOneWidget);
    expect(session.token!.jwt, 'tok');
    final enter = tester.widget<FilledButton>(
      find.byKey(const Key('enter-lobby')),
    );
    expect(enter.onPressed, isNotNull);
    session.dispose();
  });

  group('before sign-in', () {
    late FakeGateway gw;

    // setUp and tearDown run on real time; a gateway started inside the test
    // body would put its timers on the test clock (rules/testing.md).
    setUp(() async {
      // flutter_test answers every HttpClient with an empty 400; this test
      // talks to the fake over a real socket (the file is its own isolate).
      HttpOverrides.global = null;
      gw = await FakeGateway.start();
    });

    tearDown(() => gw.shutdown());

    testWidgets('the server time is read before sign-in', (tester) async {
      final session = Session(
        config: PlaygroundConfig(
          gatewayUrl: '',
          channelId: '',
          authBaseUrl: '',
          authChannelId: '',
          kvBaseUrl: gw.kvUrl.toString(),
        ),
      );
      addTearDown(session.dispose);
      tester.view.physicalSize = const Size(1280, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(PlaygroundApp(session: session));
      expect(find.text('Not signed in'), findsOneWidget);
      await tester.tap(find.byKey(const Key('server-time')));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!session.log.any((l) => l.text.startsWith('server time: '))) {
        if (DateTime.now().isAfter(deadline)) fail('no server time line');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      final line = session.log.lastWhere(
        (l) => l.text.startsWith('server time: '),
      );
      final at = DateTime.parse(line.text.substring('server time: '.length));
      expect(at.isUtc, isTrue);
      expect(
        at.difference(DateTime.now().toUtc()).inSeconds.abs(),
        lessThan(60),
      );
      // The request went out and was logged as a kind, not a URL.
      expect(
        session.log.map((l) => l.text).join('\n'),
        contains('"route":"time","status":200'),
      );
      expect(session.signedIn, isFalse);
    });
  });
}
