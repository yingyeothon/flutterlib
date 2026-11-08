import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:yingyeothon_tracer_flutter/yingyeothon_tracer_flutter.dart';

/// The service fixture DSN (`tracer/testdata/envelopes/README.md`); not a
/// real key, on a host that never resolves.
const String fixtureDsn =
    'https://fixturewritekeyfixturewritekey00@trace.invalid/trc_fixture01';

/// Records envelopes (decompressed) and answers 200.
final class FakeHttp extends http.BaseClient {
  final List<Uint8List> bodies = [];

  /// The JSON payload of item [item] of envelope [n].
  Map<String, Object?> json(int n, int item) {
    final b = bodies[n];
    var at = b.indexOf(0x0A) + 1;
    for (var i = 0; ; i++) {
      final end = b.indexOf(0x0A, at);
      final h = jsonDecode(utf8.decode(b.sublist(at, end))) as Map;
      final len = h['length']! as int;
      if (i == item) {
        return jsonDecode(utf8.decode(b.sublist(end + 1, end + 1 + len)))
            as Map<String, Object?>;
      }
      at = end + 2 + len;
    }
  }

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

/// A device_info platform that answers [data] (as the method channel
/// would), or fails when it is null.
final class FakeDeviceInfo extends DeviceInfoPlatform {
  FakeDeviceInfo(this.data);
  final Map<String, dynamic>? data;
  int calls = 0;

  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    calls++;
    final d = data;
    if (d == null) throw PlatformException(code: 'unavailable');
    return BaseDeviceInfo(d);
  }
}

/// `android.os.Build` as device_info_plus 13 sends it. `name` is the
/// user-set device name and `host`/`fingerprint` identify a build: none of
/// them may reach the wire.
Map<String, dynamic> androidBuild({String model = 'sdk_gphone64_x86_64'}) => {
  'version': {
    'baseOS': '',
    'codename': 'REL',
    'incremental': '1',
    'previewSdkInt': 0,
    'release': '16',
    'sdkInt': 36,
    'securityPatch': '2026-01-01',
  },
  'board': 'secret-board',
  'bootloader': 'unknown',
  'brand': 'google',
  'device': 'secret-device',
  'display': 'secret-display-id',
  'fingerprint': 'secret-fingerprint',
  'hardware': 'ranchu',
  'host': 'secret-host',
  'id': 'secret-build-id',
  'manufacturer': 'Google',
  'model': model,
  'product': 'secret-product',
  'name': 'Secret Phone Name',
  'supported32BitAbis': <String>[],
  'supported64BitAbis': <String>['x86_64'],
  'supportedAbis': <String>['x86_64'],
  'tags': 'release-keys',
  'time': 0,
  'type': 'userdebug',
  'isPhysicalDevice': false,
  'freeDiskSize': 1,
  'totalDiskSize': 2,
  'systemFeatures': <String>[],
  'isLowRamDevice': false,
  'physicalRamSize': 2048,
  'availableRamSize': 1024,
};

/// `UIDevice` and `utsname` as device_info_plus 13 sends them.
Map<String, dynamic> iosDevice() => {
  'name': 'Secret iPhone Name',
  'systemName': 'iOS',
  'systemVersion': '19.1',
  'model': 'iPhone',
  'modelName': 'iPhone 15 Pro',
  'localizedModel': 'iPhone',
  'identifierForVendor': 'SECRET-VENDOR-ID',
  'freeDiskSize': 1,
  'totalDiskSize': 2,
  'isPhysicalDevice': true,
  'physicalRamSize': 8192,
  'availableRamSize': 4096,
  'isiOSAppOnMac': false,
  'isiOSAppOnVision': false,
  'utsname': {
    'sysname': 'Darwin',
    'nodename': 'secret-node',
    'release': '25.0.0',
    'version': 'Darwin Kernel',
    'machine': 'iPhone16,1',
  },
};

void mockPackage({String packageName = 'life.yyt.app', String build = '7'}) =>
    PackageInfo.setMockInitialValues(
      appName: 'App',
      packageName: packageName,
      version: '1.2.3',
      buildNumber: build,
      buildSignature: 'SECRET-SIGNATURE',
      installerStore: 'secret.installer.store',
    );

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('Android: device, OS and a derived release, after init', (
    tester,
  ) async {
    final device = FakeDeviceInfo(androidBuild());
    DeviceInfoPlatform.instance = device;
    mockPackage();
    final fake = FakeHttp();
    final tracer = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    // Returned before the platform answered: the first event goes without.
    expect(tracer.enabled, isTrue);
    await tracer.report('early');
    await tester.pump();
    final early = fake.json(0, 0);
    expect((early['contexts']! as Map)['os'], {'name': 'Android'});
    expect((early['contexts']! as Map).containsKey('device'), isFalse);
    expect(early.containsKey('release'), isFalse);

    await TracerFlutter.platformReady;
    await tracer.report('later');
    tracer.log(TracerLevel.info, 'line');
    await tracer.flush();
    await tester.pump();
    final event = fake.json(1, 0);
    final contexts = event['contexts']! as Map;
    expect(contexts['device'], {
      'model': 'sdk_gphone64_x86_64',
      'manufacturer': 'Google',
      'brand': 'google',
      'family': 'sdk_gphone64_x86_64',
      'simulator': true,
    });
    expect(contexts['os'], {'name': 'Android', 'version': '16'});
    expect(event['release'], 'life.yyt.app@1.2.3+7');
    final line = jsonEncode(fake.json(2, 0));
    expect(line, contains('"device.model":{"value":"sdk_gphone64_x86_64"'));
    expect(line, contains('"sentry.release":{"value":"life.yyt.app@1.2.3+7"'));
    final all = fake.bodies.map(utf8.decode).join();
    expect(all, contains('sdk_gphone64_x86_64'), reason: 'positive control');
    expect(all.toLowerCase(), isNot(contains('secret')));

    // A second init reuses the read: the platform is asked once.
    final second = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    await tester.pump();
    await second.report('second');
    await tester.pump();
    expect(
      fake.json(fake.bodies.length - 1, 0)['release'],
      'life.yyt.app@1.2.3+7',
    );
    expect(device.calls, 1);
    await TracerFlutter.dispose();
  });

  testWidgets('family is the first word of a spaced model', (tester) async {
    DeviceInfoPlatform.instance = FakeDeviceInfo(
      androidBuild(model: 'Pixel 9 Pro'),
    );
    mockPackage(build: '');
    final fake = FakeHttp();
    final tracer = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    await tester.pump();
    await tracer.report('r');
    await tester.pump();
    final event = fake.json(0, 0);
    expect(((event['contexts']! as Map)['device'] as Map)['family'], 'Pixel');
    expect(event['release'], 'life.yyt.app@1.2.3', reason: 'no build number');
    await TracerFlutter.dispose();
  });

  testWidgets('iOS: the model name, the hardware id, never the name', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    DeviceInfoPlatform.instance = FakeDeviceInfo(iosDevice());
    mockPackage();
    final fake = FakeHttp();
    final tracer = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    await tester.pump();
    await tracer.report('r');
    await tester.pump();
    final contexts = fake.json(0, 0)['contexts']! as Map;
    expect(contexts['device'], {
      'model': 'iPhone 15 Pro',
      'model_id': 'iPhone16,1',
      'manufacturer': 'Apple',
      'brand': 'Apple',
      'family': 'iPhone',
      'simulator': false,
    });
    expect(contexts['os'], {'name': 'iOS', 'version': '19.1'});
    final all = utf8.decode(fake.bodies.single);
    expect(all, contains('iPhone16,1'), reason: 'positive control');
    expect(all.toLowerCase(), isNot(contains('secret')));
    await TracerFlutter.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS: a model the plugin does not know is the hardware id', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    DeviceInfoPlatform.instance = FakeDeviceInfo({
      ...iosDevice(),
      'modelName': 'Unknown device',
      'utsname': {...iosDevice()['utsname'] as Map, 'machine': 'iPhone99,9'},
    });
    mockPackage();
    final fake = FakeHttp();
    final tracer = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    await tester.pump();
    await tracer.report('r');
    await tester.pump();
    final device = (fake.json(0, 0)['contexts']! as Map)['device'] as Map;
    expect(device['model'], 'iPhone99,9');
    expect(device['model_id'], 'iPhone99,9');
    await TracerFlutter.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('readPlatform: false reads nothing', (tester) async {
    final device = FakeDeviceInfo(androidBuild());
    DeviceInfoPlatform.instance = device;
    mockPackage();
    final fake = FakeHttp();
    final tracer = TracerFlutter.initUi(
      dsn: fixtureDsn,
      readPlatform: false,
      client: fake,
    );
    await tester.pump();
    await tracer.report('r');
    await tester.pump();
    final event = fake.json(0, 0);
    expect(device.calls, 0);
    expect(event.containsKey('release'), isFalse);
    expect((event['contexts']! as Map).containsKey('device'), isFalse);
    await TracerFlutter.dispose();
  });

  testWidgets('what the app passed wins over the platform', (tester) async {
    DeviceInfoPlatform.instance = FakeDeviceInfo(androidBuild());
    mockPackage();
    final fake = FakeHttp();
    final tracer = TracerFlutter.initUi(
      dsn: fixtureDsn,
      release: 'mine@9',
      contexts: const {
        'device': {'model': 'own'},
        'os': {'name': 'OwnOS'},
      },
      client: fake,
    );
    await tester.pump();
    await tracer.report('r');
    await tester.pump();
    final event = fake.json(0, 0);
    expect(event['release'], 'mine@9');
    expect((event['contexts']! as Map)['device'], {'model': 'own'});
    expect((event['contexts']! as Map)['os'], {'name': 'OwnOS'});
    await TracerFlutter.dispose();
  });

  testWidgets('a failing device read keeps the client and the release', (
    tester,
  ) async {
    DeviceInfoPlatform.instance = FakeDeviceInfo(null);
    mockPackage();
    final fake = FakeHttp();
    final tracer = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    await tester.pump();
    expect(tracer.enabled, isTrue);
    await tracer.report('r');
    await tester.pump();
    final event = fake.json(0, 0);
    expect((event['contexts']! as Map)['os'], {'name': 'Android'});
    expect((event['contexts']! as Map).containsKey('device'), isFalse);
    expect(event['release'], 'life.yyt.app@1.2.3+7');
    expect(tracer.stats.dropped, isEmpty);
    await TracerFlutter.dispose();

    // No package name: no release rather than a half one.
    mockPackage(packageName: '');
    final again = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    await tester.pump();
    await again.report('r2');
    await tester.pump();
    expect(fake.json(1, 0).containsKey('release'), isFalse);
    await TracerFlutter.dispose();
  });

  testWidgets('desktop and background isolates read no device', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final device = FakeDeviceInfo(androidBuild());
    DeviceInfoPlatform.instance = device;
    mockPackage();
    final fake = FakeHttp();
    final ui = TracerFlutter.initUi(dsn: fixtureDsn, client: fake);
    await tester.pump();
    await ui.report('r');
    await tester.pump();
    final event = fake.json(0, 0);
    expect((event['contexts']! as Map)['os'], {'name': 'Linux'});
    expect((event['contexts']! as Map).containsKey('device'), isFalse);
    expect(event['release'], 'life.yyt.app@1.2.3+7');
    expect(device.calls, 0);
    await TracerFlutter.dispose();

    final bg = TracerFlutter.initBackground(dsn: fixtureDsn, client: fake);
    await tester.pump();
    await bg.report('bg');
    await tester.pump();
    expect(fake.json(1, 0).containsKey('release'), isFalse);
    expect(device.calls, 0);
    await TracerFlutter.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an off client reads nothing', (tester) async {
    final device = FakeDeviceInfo(androidBuild());
    DeviceInfoPlatform.instance = device;
    final tracer = TracerFlutter.initUi();
    await tester.pump();
    expect(tracer.state, TracerState.off);
    expect(device.calls, 0);
    var ready = false;
    unawaited(TracerFlutter.platformReady.then((_) => ready = true));
    await tester.pump();
    expect(ready, isTrue);
    await TracerFlutter.dispose();
  });
}
