// The client over a real `package:http` client against the dev CDN, when
// `YYT_ASSET_BASE_URL` names a bundle (`https://dev-d.yyt.life/assets/{id}/`)
// and `YYT_ASSET_FILE` a file in it larger than two segments (131,000 bytes or
// more); `YYT_ASSET_KEY` is the bundle's key when it is encrypted, and
// `YYT_ASSET_MANIFEST` (default `manifest.json`) a JSON file in it, whose
// `"v"` must equal `YYT_ASSET_MANIFEST_V` when that is set — how a replaced
// manifest is proven to read back new. Without the first two it is skipped,
// never failed. No value is ever printed.
@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:yingyeothon_asset_client/yingyeothon_asset_client.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';

final class _Memory implements AssetSink {
  final BytesBuilder bytes = BytesBuilder();
  @override
  void write(Uint8List chunk) => bytes.add(Uint8List.fromList(chunk));
  @override
  void reset() => bytes.clear();
}

void main() {
  final env = Platform.environment;
  final baseUrl = env['YYT_ASSET_BASE_URL'];
  final file = env['YYT_ASSET_FILE'];
  final skip = baseUrl == null || file == null
      ? 'YYT_ASSET_BASE_URL and YYT_ASSET_FILE are not set'
      : null;

  test(
    'dev: manifest, whole file, ranges across segments, download',
    () async {
      final bundle = AssetBundleClient(
        AssetBundleClientOptions(baseUrl: baseUrl!, key: env['YYT_ASSET_KEY']),
      );
      addTearDown(bundle.close);
      final manifest = await bundle.readJson(
        env['YYT_ASSET_MANIFEST'] ?? 'manifest.json',
        noCache: true,
      );
      expect(manifest, isA<JsonObject>());
      final expectV = env['YYT_ASSET_MANIFEST_V'];
      if (expectV != null) {
        expect('${(manifest! as JsonObject)['v']}', expectV);
      }

      final whole = await bundle.read(file!);
      expect(whole.length, greaterThanOrEqualTo(131000));
      // Windows that straddle the first and the second segment boundary.
      for (final (a, b) in <(int, int)>[
        (65400, 65600),
        (130900, 131000),
        (0, 1),
        (whole.length - 1, whole.length),
      ]) {
        expect(
          await bundle.readRange(file, start: a, end: b),
          Uint8List.sublistView(whole, a, b),
          reason: '[$a, $b)',
        );
      }
      final sink = _Memory();
      final result = await bundle.download(file, sink: sink);
      expect(result.bytes, whole.length);
      expect(sink.bytes.takeBytes(), whole);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
