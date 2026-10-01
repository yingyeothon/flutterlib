// Conformance against the service repository's `docs/asset-encryption-vectors.json`
// (copied into test/fixtures from service commit f6c418a, 2026-09-28): every
// positive case decrypts, whole and by any range, and every negative case is
// asset_corrupt, in both request modes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:yingyeothon_asset_client/yingyeothon_asset_client.dart';

import 'support/fake_cdn.dart';

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

const String _base = 'https://dev-d.yyt.life/assets/ab_vectors/';

void main() {
  final vectors = jsonDecode(
    File('test/fixtures/asset-encryption-vectors.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final positive = (vectors['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();
  final negative = (vectors['negative']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the fixture holds the cases the spec lists', () {
    expect(positive, hasLength(7));
    expect(negative, hasLength(9));
    expect(vectors['format'], 'yyt-enc-v1');
  });

  for (final crossOrigin in <bool>[false, true]) {
    final mode = crossOrigin ? 'browser mode' : 'conditional mode';
    ({FakeCdn cdn, AssetBundleClient client}) setup(Map<String, Object?> c) {
      final cdn = FakeCdn(crossOrigin: crossOrigin);
      final path = c['path']! as String;
      cdn.serve(
        _base + path.split('/').map(Uri.encodeComponent).join('/'),
        _hex(c['ciphertextHex']! as String),
      );
      final client = AssetBundleClient(
        AssetBundleClientOptions(
          baseUrl: _base,
          key: c['key']! as String,
          corsSafe: crossOrigin,
          client: cdn,
        ),
      );
      return (cdn: cdn, client: client);
    }

    group(mode, () {
      for (final c in positive) {
        final name = c['name']! as String;
        final unit = _hex(c['plaintextUnitHex']! as String);
        final length = c['plaintextLength']! as int;
        final plain = Uint8List(length);
        for (var i = 0; i < length; i++) {
          plain[i] = unit[i % unit.length];
        }

        test('$name: whole, and by ranges across every boundary', () async {
          final s = setup(c);
          final path = c['path']! as String;
          expect(await s.client.read(path), plain);
          final cuts = <int>{
            0,
            1,
            65463,
            65464,
            65465,
            130967,
            130968,
            130969,
            length - 1,
            length,
          }.where((p) => p >= 0 && p <= length).toList()..sort();
          for (final a in cuts) {
            for (final b in cuts.where((b) => b > a)) {
              expect(
                await s.client.readRange(path, start: a, end: b),
                Uint8List.sublistView(plain, a, b),
                reason: '[$a, $b)',
              );
            }
          }
          expect(await s.client.readRange(path, start: 0), plain);
          expect(s.cdn.openBodies, 0);
        });
      }

      for (final c in negative) {
        test('${c['name']}: asset_corrupt, whole and by range', () async {
          final s = setup(c);
          final path = c['path']! as String;
          for (final read in <Future<Object?> Function()>[
            () => s.client.read(path),
            () => s.client.readRange(path, start: 0),
          ]) {
            await expectLater(
              read(),
              throwsA(
                isA<AssetClientException>().having(
                  (e) => e.code,
                  'code',
                  AssetClientErrorCode.assetCorrupt,
                ),
              ),
            );
          }
          expect(s.cdn.openBodies, 0);
        });
      }
    });
  }
}
