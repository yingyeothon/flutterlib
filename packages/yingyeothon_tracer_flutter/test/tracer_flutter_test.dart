import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:yingyeothon_tracer_flutter/yingyeothon_tracer_flutter.dart';

/// The service fixture DSN (`tracer/testdata/envelopes/README.md`); not a
/// real key, on a host that never resolves.
const String fixtureDsn =
    'https://fixturewritekeyfixturewritekey00@trace.invalid/trc_fixture01';

/// Records envelopes (decompressed) and answers 200.
final class FakeHttp extends http.BaseClient {
  final List<Uint8List> bodies = [];

  /// Items of envelope [n]: header map and payload bytes.
  List<(Map<String, Object?>, Uint8List)> items(int n) {
    final b = bodies[n];
    var at = b.indexOf(0x0A) + 1;
    final out = <(Map<String, Object?>, Uint8List)>[];
    while (at < b.length) {
      final end = b.indexOf(0x0A, at);
      final h =
          jsonDecode(utf8.decode(b.sublist(at, end))) as Map<String, Object?>;
      final len = h['length']! as int;
      out.add((h, b.sublist(end + 1, end + 1 + len)));
      at = end + 2 + len;
    }
    return out;
  }

  Map<String, Object?> json(int n, int item) =>
      jsonDecode(utf8.decode(items(n)[item].$2)) as Map<String, Object?>;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final raw = (request as http.Request).bodyBytes;
    bodies.add(
      request.headers['content-encoding'] == 'gzip'
          ? Uint8List.fromList(gzip.decode(raw))
          : raw,
    );
    return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
  }
}

List<Object?> crumbs(Map<String, Object?> event) =>
    ((event['breadcrumbs']! as Map)['values'] as List)
        .map((b) => '${(b as Map)['category']}:${b['message']}')
        .toList();

void main() {
  test('the defines are empty without --dart-define', () {
    expect(TracerDefines.dsn, '');
    expect(TracerDefines.gitSha, '');
  });

  testWidgets('an empty DSN is off and installs nothing', (tester) async {
    final before = FlutterError.onError;
    final tracer = TracerFlutter.initUi();
    expect(tracer.state, TracerState.off);
    expect(Tracer.current, same(tracer));
    expect(FlutterError.onError, same(before));
    await TracerFlutter.dispose();
  });

  testWidgets('initUi: tags, dist, hooks that chain, lifecycle', (
    tester,
  ) async {
    final fake = FakeHttp();
    final seen = <String>[];
    final flutterBefore = FlutterError.onError;
    FlutterError.onError = (d) => seen.add('flutter');
    final platformBefore = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (e, s) {
      seen.add('platform');
      return true;
    };
    final tracer = TracerFlutter.initUi(
      dsn: fixtureDsn,
      release: 'app@1.0.0+1',
      gitSha: 'abc1234',
      tags: {'feature': 'board'},
      client: fake,
    );
    expect(tracer.enabled, isTrue);

    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('boom'), library: 'widgets'),
    );
    final handled = ui.PlatformDispatcher.instance.onError!(
      ArgumentError('x'),
      StackTrace.empty,
    );
    expect(handled, isTrue);
    expect(seen, ['flutter', 'platform']);

    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pump();
    // `paused` flushed the two error log lines.
    expect(fake.bodies, hasLength(1));
    expect(fake.items(0).single.$1['item_count'], 2);

    await tracer.report('r');
    await tester.pump();
    final event = fake.json(1, 0);
    expect(event['tags'], {
      'git_sha': 'abc1234',
      'feature': 'board',
      'isolate': 'ui',
    });
    expect(event['dist'], 'abc1234');
    expect(event['release'], 'app@1.0.0+1');
    expect(event['environment'], 'debug');
    expect((event['contexts']! as Map)['os'], {'name': 'Android'});
    expect(crumbs(event), [
      'flutter.error:Bad state: boom',
      'platform.error:Invalid argument(s): x',
      'app.lifecycle:inactive',
      'app.lifecycle:hidden',
      'app.lifecycle:paused',
    ]);

    // A second init swaps the client; the hooks are not stacked twice.
    final second = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    await tester.pump();
    expect(tracer.state, TracerState.closed);
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('two')));
    expect(seen, ['flutter', 'platform', 'flutter']);
    await second.report('r2');
    await tester.pump();
    expect(crumbs(fake.json(fake.bodies.length - 1, 0)), [
      'flutter.error:Bad state: two',
    ]);

    await TracerFlutter.dispose();
    expect(Tracer.current.state, TracerState.closed);
    FlutterError.onError = flutterBefore;
    ui.PlatformDispatcher.instance.onError = platformBefore;
  });

  testWidgets('without a previous handler the error is presented', (
    tester,
  ) async {
    final flutterBefore = FlutterError.onError;
    FlutterError.onError = null;
    final presented = <String>[];
    final presentBefore = FlutterError.presentError;
    FlutterError.presentError = (d) => presented.add(d.exceptionAsString());
    TracerFlutter.initUi(dsn: fixtureDsn, client: FakeHttp(), lifecycle: false);
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('p')));
    expect(presented, ['Bad state: p']);
    expect(
      ui.PlatformDispatcher.instance.onError!(
        StateError('q'),
        StackTrace.empty,
      ),
      isFalse,
    );
    await TracerFlutter.dispose();
    FlutterError.presentError = presentBefore;
    FlutterError.onError = flutterBefore;
  });

  testWidgets('dispose leaves a handler installed after tracer alone', (
    tester,
  ) async {
    final flutterBefore = FlutterError.onError;
    TracerFlutter.initUi(dsn: fixtureDsn, client: FakeHttp(), lifecycle: false);
    void later(FlutterErrorDetails d) {}
    FlutterError.onError = later;
    await TracerFlutter.dispose();
    expect(FlutterError.onError, same(later));
    FlutterError.onError = flutterBefore;
  });

  testWidgets('error text stays in the breadcrumb; the log has the type', (
    tester,
  ) async {
    final fake = FakeHttp();
    final flutterBefore = FlutterError.onError;
    FlutterError.onError = (_) {};
    final tracer = TracerFlutter.initUi(
      dsn: fixtureDsn,
      client: fake,
      lifecycle: false,
    );
    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('secret input')),
    );
    await tracer.flush();
    await tester.pump();
    final line = utf8.decode(fake.items(0).single.$2);
    expect(line, contains('"body":"flutter.error"'));
    expect(line, contains('"value":"StateError"'));
    expect(line, isNot(contains('secret input')));
    await TracerFlutter.dispose();
    FlutterError.onError = flutterBefore;
  });

  testWidgets('scrubError rewrites the text; null or a throw keeps the type', (
    tester,
  ) async {
    final fake = FakeHttp();
    final flutterBefore = FlutterError.onError;
    FlutterError.onError = (_) {};
    final platformBefore = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (e, s) => true;
    addTearDown(() async {
      await TracerFlutter.dispose();
      FlutterError.onError = flutterBefore;
      ui.PlatformDispatcher.instance.onError = platformBefore;
    });
    final seen = <String>[];
    final tracer = TracerFlutter.initUi(
      dsn: fixtureDsn,
      client: fake,
      lifecycle: false,
      scrubError: (error, text) {
        seen.add('${error.runtimeType}|$text');
        if (text.contains('drop')) return null;
        if (text.contains('empty')) return '';
        if (text.contains('reenter')) {
          FlutterError.reportError(
            FlutterErrorDetails(exception: StateError('inner reenter')),
          );
        }
        if (text.contains('throw')) throw StateError('scrubber failed');
        return text.replaceAll(RegExp(r'\d'), '#');
      },
    );
    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('card 1234')),
    );
    ui.PlatformDispatcher.instance.onError!(
      ArgumentError('drop me'),
      StackTrace.empty,
    );
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('throw')));
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('empty')));
    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('reenter 5')),
    );
    await tracer.report('r0');
    await tester.pump();
    final first = fake.json(fake.bodies.length - 1, 0);
    expect(crumbs(first), [
      'flutter.error:Bad state: card ####',
      'platform.error:ArgumentError',
      'flutter.error:StateError',
      'flutter.error:StateError',
      'flutter.error:StateError',
      'flutter.error:Bad state: reenter #',
    ]);
    expect(jsonEncode(first), isNot(contains('drop me')));
    expect(jsonEncode(first), isNot(contains('inner reenter')));
    expect(jsonEncode(first), isNot(contains('scrubber failed')));
    // A later init keeps the first call's scrubber (the hooks are not
    // reinstalled), and a scrubber passed then is ignored.
    final second = TracerFlutter.initUi(
      dsn: fixtureDsn,
      client: fake,
      scrubError: (error, text) => 'second',
    );
    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('after 9')),
    );
    expect(seen, [
      'StateError|Bad state: card 1234',
      'ArgumentError|Invalid argument(s): drop me',
      'StateError|Bad state: throw',
      'StateError|Bad state: empty',
      'StateError|Bad state: reenter 5',
      'StateError|Bad state: after 9',
    ]);
    await second.report('r');
    await tester.pump();
    expect(tracer.state, TracerState.closed);
    expect(crumbs(fake.json(fake.bodies.length - 1, 0)), [
      'flutter.error:Bad state: after #',
    ]);
    await TracerFlutter.dispose();

    // After dispose a new init installs fresh hooks with no scrubber.
    final third = TracerFlutter.initUi(
      dsn: fixtureDsn,
      client: fake,
      lifecycle: false,
    );
    FlutterError.onError!(FlutterErrorDetails(exception: StateError('raw 7')));
    await third.report('r3');
    await tester.pump();
    expect(crumbs(fake.json(fake.bodies.length - 1, 0)), [
      'flutter.error:Bad state: raw 7',
    ]);
    await TracerFlutter.dispose();
    FlutterError.onError = flutterBefore;
    ui.PlatformDispatcher.instance.onError = platformBefore;
  });

  testWidgets('a scrubbed-away text leaves the type in the breadcrumb', (
    tester,
  ) async {
    final fake = FakeHttp();
    final flutterBefore = FlutterError.onError;
    FlutterError.onError = (_) {};
    final tracer = TracerFlutter.initUi(
      dsn: fixtureDsn,
      client: fake,
      lifecycle: false,
      scrubError: (error, text) => null,
    );
    addTearDown(() async {
      await TracerFlutter.dispose();
      FlutterError.onError = flutterBefore;
    });
    FlutterError.onError!(
      FlutterErrorDetails(exception: StateError('secret input')),
    );
    await tracer.report('r');
    await tester.pump();
    final event = fake.json(fake.bodies.length - 1, 0);
    expect(crumbs(event), ['flutter.error:StateError']);
    expect(jsonEncode(event), isNot(contains('secret input')));
    await TracerFlutter.dispose();
    FlutterError.onError = flutterBefore;
  });

  testWidgets('initBackground: a plain client tagged with its isolate', (
    tester,
  ) async {
    final fake = FakeHttp();
    final before = FlutterError.onError;
    final tracer = TracerFlutter.initBackground(
      dsn: fixtureDsn,
      isolate: 'ble',
      client: fake,
    );
    expect(FlutterError.onError, same(before));
    await tracer.report('bg');
    await tester.pump();
    expect(fake.json(0, 0)['tags'], {'isolate': 'ble'});
    expect(fake.json(0, 0).containsKey('dist'), isFalse);
    await TracerFlutter.dispose();
  });

  testWidgets('navigation breadcrumbs', (tester) async {
    final fake = FakeHttp();
    final tracer = TracerClient(TracerOptions(dsn: fixtureDsn, client: fake));
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        navigatorObservers: [TracerNavigatorObserver(client: tracer)],
        routes: {
          '/': (_) => const Text('home'),
          '/board': (_) => const Text('board'),
          '/end': (_) => const Text('end'),
        },
      ),
    );
    key.currentState!.pushNamed('/board');
    await tester.pumpAndSettle();
    key.currentState!.pushReplacementNamed('/end');
    await tester.pumpAndSettle();
    key.currentState!.pop();
    await tester.pumpAndSettle();
    key.currentState!.push(
      PageRouteBuilder<void>(pageBuilder: (_, _, _) => const Text('anon')),
    );
    await tester.pumpAndSettle();
    key.currentState!.removeRoute(
      ModalRoute.of(tester.element(find.text('anon')))!,
    );
    await tester.pumpAndSettle();
    await tracer.report('r');
    await tester.pump();
    final event = fake.json(0, 0);
    expect(crumbs(event), [
      'navigation:push /',
      'navigation:push /board',
      'navigation:replace /end',
      'navigation:pop /',
      'navigation:push (anonymous)',
      'navigation:remove /',
    ]);
    final values = (event['breadcrumbs']! as Map)['values'] as List;
    expect((values[1] as Map)['data'], {'from': '/', 'to': '/board'});
    await tracer.close();
  });

  testWidgets('screenshot and view hierarchy', (tester) async {
    expect(await tester.runAsync(TracerScreenshot.capture), isNull);
    await tester.pumpWidget(
      const TracerScreenshot(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Text('hello', key: Key('greeting')),
        ),
      ),
    );
    final png = await tester.runAsync(TracerScreenshot.capture);
    expect(png, isNotNull);
    expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    final tree = jsonDecode(
      utf8.decode(TracerScreenshot.viewHierarchy()),
    ) as Map<String, Object?>;
    expect(tree['rendering_system'], 'flutter');
    final text = jsonEncode(tree);
    expect(text, contains('"type":"RepaintBoundary"'));
    expect(text, contains('"identifier":"ValueKey<String>"'));
    expect(text, isNot(contains('greeting')), reason: 'no key values');
    expect(text, isNot(contains('hello')), reason: 'no text content');
    final small = jsonDecode(
      utf8.decode(TracerScreenshot.viewHierarchy(maxNodes: 1)),
    ) as Map<String, Object?>;
    expect(((small['windows']! as List).single as Map)['children'], isNull);
  });

  testWidgets('report this: event with attachments, then the note', (
    tester,
  ) async {
    final fake = FakeHttp();
    final tracer = TracerClient(TracerOptions(dsn: fixtureDsn, client: fake));
    await tester.pumpWidget(
      TracerScreenshot(
        child: MaterialApp(
          home: Scaffold(body: TracerReportButton(client: tracer)),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('tracer-report')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(fake.bodies, hasLength(1));
    final items = fake.items(0);
    expect(items.map((i) => i.$1['filename']), [
      null,
      'screenshot.png',
      'view-hierarchy.json',
    ]);
    expect(items[1].$2.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    final eventId = fake.json(0, 0)['event_id'];
    expect(fake.json(0, 0)['message'], 'report this');

    await tester.enterText(
      find.byKey(const Key('tracer-note')),
      'knight vanished',
    );
    await tester.tap(find.byKey(const Key('tracer-note-send')));
    await tester.pumpAndSettle();
    // reportThis started in runAsync's real zone, so it continues there.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(fake.bodies, hasLength(2));
    expect((fake.json(1, 0)['contexts']! as Map)['feedback'], {
      'message': 'knight vanished',
      'associated_event_id': eventId,
    });
    await tracer.close();
  });

  testWidgets('report this: cancel sends no note', (tester) async {
    final fake = FakeHttp();
    final tracer = TracerClient(TracerOptions(dsn: fixtureDsn, client: fake));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TracerReportButton(client: tracer)),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('tracer-report')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(fake.bodies, hasLength(1));
    // Without TracerScreenshot there is no PNG; the hierarchy still goes.
    expect(fake.items(0).map((i) => i.$1['filename']), [
      null,
      'view-hierarchy.json',
    ]);
    await tester.tap(find.byKey(const Key('tracer-note-cancel')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(fake.bodies, hasLength(1));
    await tracer.close();
  });

  testWidgets('report this with tracer off does nothing', (tester) async {
    final off = TracerClient(const TracerOptions(dsn: ''));
    late BuildContext ctx;
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox();
        },
      ),
    );
    expect(await TracerReportButton.reportThis(ctx, client: off), isNull);
  });
}
