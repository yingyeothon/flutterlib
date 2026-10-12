import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yyt_playground/debug/platform_demo_io.dart';
import 'package:yyt_playground/screens/platform_screen.dart';
import 'package:yyt_playground/session.dart';

void main() {
  testWidgets('offline platform demo completes both modes and cleans push', (
    tester,
  ) async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    final lines = await tester.runAsync(runPlatformDemo);
    expect(lines, [
      'Live match: 2 members',
      'Deferred match: confirmed',
      'Push: 1 registered, wake true, 0 after sign-out',
    ]);
    await tester.pump(const Duration(seconds: 16));
  });
  testWidgets('Android adapter is optional and offline action is visible', (
    tester,
  ) async {
    final session = Session();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(home: PlatformScreen(session: session)),
    );
    expect(find.text('Run offline match and push'), findsOneWidget);
    await tester.tap(find.text('Start Android push'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in first'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
