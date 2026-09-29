// Drives the asset screen against the in-process fake gateway's `/assets/*`
// CDN over the real http client, an encrypted bundle and a plain one.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yyt_playground/config.dart';
import 'package:yyt_playground/main.dart';
import 'package:yyt_playground/screens/asset_screen.dart';
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

Uint8List keyOf(int fill) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 13 + fill) & 0xff));

void main() {
  late FakeGateway gw;
  late Session session;
  final key = keyOf(3);
  final files = <String, List<int>>{
    'manifest.json': utf8.encode('{"v":1,"files":["hello.txt","big.bin"]}'),
    'hello.txt': utf8.encode('hello, bundle'),
    'big.bin': List<int>.generate(200000, (i) => i & 0xff),
  };

  setUp(() async {
    // flutter_test answers every HttpClient with an empty 400; the asset
    // client talks to the fake over a real socket.
    HttpOverrides.global = null;
    gw = await FakeGateway.start(
      options: FakeGatewayOptions(
        assetBundles: <FakeAssetBundle>[
          FakeAssetBundle(id: 'ab_enc', key: key, files: files),
          FakeAssetBundle(id: 'ab_plain', files: files),
        ],
      ),
    );
    session = Session(
      config: PlaygroundConfig(
        gatewayUrl: '',
        channelId: '',
        authBaseUrl: '',
        authChannelId: '',
        assetBaseUrl: gw.assetsUrl.resolve('ab_enc/').toString(),
        assetKey: assetKeyText(key),
      ),
    );
  });

  tearDown(() async {
    session.dispose();
    await gw.shutdown();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(
      () => tester.pumpWidget(PlaygroundApp(session: session)),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await pumpApp(tester);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed(AssetScreen.route);
    await pumpUntil(tester, () => session.manifest != null);
    await tester.pumpAndSettle();
  }

  testWidgets('reads the manifest, a text file and downloads a binary', (
    tester,
  ) async {
    await open(tester);
    expect(
      find.text('{"v":1,"files":["hello.txt","big.bin"]}'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('text-read')));
    await pumpUntil(tester, () => session.assetText != null);
    await tester.pumpAndSettle();
    expect(find.text('hello, bundle'), findsOneWidget);
    await tester.tap(find.byKey(const Key('download-start')));
    await pumpUntil(tester, () => session.downloaded != null);
    await tester.pumpAndSettle();
    expect(find.text('Downloaded 200000 bytes'), findsOneWidget);
    expect(session.downloadProgress?.written, 200000);
    expect(session.downloadProgress?.total, 200000);
    expect(find.byKey(const Key('close-banner')), findsNothing);
    // Positive control, then the negative: the SDK logged its requests and
    // no line carries the key.
    expect(session.log.any((l) => l.text.contains('asset request')), isTrue);
    // A 16-character window, so a truncated key is caught as well.
    final window = assetKeyText(key).substring(10, 26);
    expect(session.log.every((l) => !l.text.contains(window)), isTrue);
    expect(find.textContaining(window), findsNothing);
  });

  testWidgets('a wrong key is a corrupt bundle, named by its code', (
    tester,
  ) async {
    session.updateConfig(
      session.config.copyWith(assetKey: assetKeyText(keyOf(9))),
    );
    await pumpApp(tester);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed(AssetScreen.route);
    await pumpUntil(
      tester,
      () => find.byKey(const Key('close-banner')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'corrupt: a wrong or missing key, a base URL that is not the bundle, '
        'or a tampered file',
      ),
      findsOneWidget,
    );
    expect(session.manifest, isNull);
    // Positive control (the refused read was logged), then the negative:
    // neither key's text reaches the log or the screen.
    expect(session.log.any((l) => l.text.contains('asset request')), isTrue);
    for (final k in <String>[assetKeyText(key), assetKeyText(keyOf(9))]) {
      final window = k.substring(10, 26);
      expect(session.log.every((l) => !l.text.contains(window)), isTrue);
      expect(find.textContaining(window), findsNothing);
    }
  });

  testWidgets('a base URL the client refuses shows its message', (
    tester,
  ) async {
    session.updateConfig(
      session.config.copyWith(
        assetBaseUrl: gw.assetsUrl.resolve('ab_enc/sub/dir/').toString(),
      ),
    );
    await pumpApp(tester);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed(AssetScreen.route);
    await pumpUntil(
      tester,
      () => find.byKey(const Key('close-banner')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('baseUrl must be'), findsOneWidget);
    expect(find.textContaining('127.0.0.1'), findsNothing);
  });

  testWidgets('leaving the screen closes the reader cleanly', (tester) async {
    await open(tester);
    expect(session.assets, isNotNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(session.assets, isNull);
    expect(find.byKey(const Key('open-assets')), findsOneWidget);
  });

  testWidgets('a malformed key is bad_key, shown without the key', (
    tester,
  ) async {
    session.updateConfig(session.config.copyWith(assetKey: 'yak1.short'));
    await pumpApp(tester);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed(AssetScreen.route);
    await pumpUntil(
      tester,
      () => find.byKey(const Key('close-banner')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('bad key: YYT_ASSET_KEY is not a canonical yak1. key'),
      findsOneWidget,
    );
    expect(find.textContaining('short'), findsNothing);
  });

  testWidgets('the login screen says what is missing', (tester) async {
    session.updateConfig(session.config.copyWith(assetBaseUrl: ''));
    await pumpApp(tester);
    await tester.ensureVisible(find.byKey(const Key('open-assets')));
    await tester.tap(find.byKey(const Key('open-assets')));
    await tester.pumpAndSettle();
    expect(find.text('Bad state: asset base URL is required'), findsOneWidget);
    expect(find.byType(AssetScreen), findsNothing);
  });

  testWidgets('a plain bundle reads without a key', (tester) async {
    session.updateConfig(
      session.config.copyWith(
        assetBaseUrl: gw.assetsUrl.resolve('ab_plain/').toString(),
        assetKey: '',
      ),
    );
    await open(tester);
    expect(find.text('No key: read as a plain bundle'), findsOneWidget);
    expect(
      find.text('{"v":1,"files":["hello.txt","big.bin"]}'),
      findsOneWidget,
    );
  });

  testWidgets(
    'the login screen opens it and keeps the key it has no field for',
    (tester) async {
      await pumpApp(tester);
      expect(
        find.text('key from YYT_ASSET_KEY: read as encrypted'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const Key('open-assets')));
      await tester.tap(find.byKey(const Key('open-assets')));
      await pumpUntil(tester, () => session.manifest != null);
      await tester.pumpAndSettle();
      expect(find.byType(AssetScreen), findsOneWidget);
      expect(session.config.assetKey, assetKeyText(key));
    },
  );
}
