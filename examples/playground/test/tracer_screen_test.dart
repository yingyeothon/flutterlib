import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yingyeothon_tracer_client/yingyeothon_tracer_client.dart';
import 'package:yyt_playground/config.dart';
import 'package:yyt_playground/main.dart';
import 'package:yyt_playground/session.dart';

/// The service's fixture DSN; not a real key, on a host that never resolves.
const String fixtureDsn =
    'https://fixturewritekeyfixturewritekey00@trace.invalid/trc_fixture01';

/// Records envelope bodies (decompressed) and answers 200.
final class FakeIngest extends http.BaseClient {
  final List<String> bodies = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final raw = (request as http.Request).bodyBytes;
    bodies.add(
      utf8.decode(
        request.headers['content-encoding'] == 'gzip'
            ? gzip.decode(raw)
            : Uint8List.fromList(raw),
        allowMalformed: true,
      ),
    );
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
  }
}

Session emptySession() => Session(
  config: const PlaygroundConfig(
    gatewayUrl: '',
    channelId: '',
    authBaseUrl: '',
    authChannelId: '',
  ),
);

Future<void> openTracer(WidgetTester tester, Session session) async {
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(PlaygroundApp(session: session));
  await tester.tap(find.byKey(const Key('open-tracer')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('off without a DSN: the screen says how to turn it on', (
    tester,
  ) async {
    Tracer.init('');
    final session = emptySession();
    await openTracer(tester, session);
    expect(find.textContaining('Tracer is off'), findsOneWidget);
    final step = tester.widget<FilledButton>(
      find.byKey(const Key('tracer-step')),
    );
    expect(step.onPressed, isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    session.dispose();
  });

  testWidgets('steps, a warning, and report this with a note', (tester) async {
    final ingest = FakeIngest();
    final tracer = Tracer.init(fixtureDsn, client: ingest, release: 'p@1');
    final session = emptySession();
    await openTracer(tester, session);
    expect(find.textContaining('Tracer active'), findsOneWidget);
    // The navigation observer saw the push.
    await tester.tap(find.byKey(const Key('tracer-step')));
    await tester.tap(find.byKey(const Key('tracer-warn')));
    await tester.tap(find.byKey(const Key('tracer-flush')));
    await tester.pumpAndSettle();
    expect(ingest.bodies, hasLength(1));
    expect(ingest.bodies.single, contains('"body":"step 1"'));
    expect(ingest.bodies.single, contains('"body":"playground warning"'));

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('tracer-report-action')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(ingest.bodies, hasLength(2));
    final report = ingest.bodies[1];
    expect(report, contains('"message":"playground report"'));
    expect(report, contains('"filename":"screenshot.png"'));
    expect(report, contains('"filename":"view-hierarchy.json"'));
    expect(report, contains('"message":"push /tracer"'));
    await tester.enterText(find.byType(EditableText).last, 'it froze');
    await tester.tap(find.text('Send note'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(ingest.bodies, hasLength(3));
    expect(ingest.bodies[2], contains('"message":"it froze"'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tracer: report '), findsWidgets);

    await tracer.close();
    Tracer.init('');
    session.dispose();
  });
}
