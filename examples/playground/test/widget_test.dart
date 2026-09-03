// This file keeps the name `flutter create .` would otherwise fill with the
// counter template; it is the login screen's test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
