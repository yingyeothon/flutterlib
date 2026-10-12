import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yyt_playground/debug/game_kit_demo_io.dart';
import 'package:yyt_playground/screens/game_kit_screen.dart';
import 'package:yyt_playground/session.dart';

void main() {
  testWidgets('all kit waves run against offline servers', (tester) async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    final lines = await tester.runAsync(runGameKitDemo);
    expect(lines, hasLength(8));
    expect(lines, contains('Kit live match: 4 members in one room'));
    expect(lines, contains('Kit turns: 4 moves, final state 10'));
    expect(lines, contains('Kit deferred match: confirmed'));
    expect(lines, contains('Kit push: wake received, 0 tokens after sign-out'));
    await tester.pump(const Duration(seconds: 16));
  });
  testWidgets('configured kit asks for public config without a token field', (
    tester,
  ) async {
    final session = Session();
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home: GameKitScreen(session: session)));
    expect(find.text('Run offline kit scenarios'), findsOneWidget);
    await tester.tap(find.text('Start configured kit'));
    await tester.pumpAndSettle();
    expect(find.text('Paste the public kit-config block'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
