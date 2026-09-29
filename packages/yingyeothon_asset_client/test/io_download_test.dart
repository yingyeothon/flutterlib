import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_asset_client/yingyeothon_asset_client_io.dart';

import 'support/encrypt.dart';
import 'support/fake_cdn.dart';

const String base = 'https://dev-d.yyt.life/assets/bnd_io/';
final key = testKey(5);

/// Passes through to [inner], but the next body fails after [cut] bytes.
final class _Interrupting extends http.BaseClient {
  _Interrupting(this.inner);
  final http.Client inner;
  int? cut;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    final limit = cut;
    if (limit == null) return response;
    cut = null;
    var seen = 0;
    final failing = response.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          if (seen + chunk.length > limit) {
            sink.addError(const SocketException('reset'));
            return;
          }
          seen += chunk.length;
          sink.add(chunk);
        },
      ),
    );
    return http.StreamedResponse(
      failing,
      response.statusCode,
      headers: response.headers,
    );
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('asset_io_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('an interrupted download resumes from the part and renames at the '
      'end', () async {
    final cdn = FakeCdn();
    final client = _Interrupting(cdn);
    final bundle = AssetBundleClient(
      AssetBundleClientOptions(baseUrl: base, key: key.text, client: client),
    );
    final plain = pattern(200000);
    cdn.serve('${base}song.ogg', encryptAsset(key.bytes, 'song.ogg', plain));
    final destination = '${dir.path}/song.ogg';

    client.cut = 100000; // inside segment 1
    await expectLater(
      downloadToFile(bundle, 'song.ogg', destination),
      throwsA(isA<AssetClientException>()),
    );
    expect(File(destination).existsSync(), isFalse);
    expect(File('$destination.part').lengthSync(), 65464);
    expect(File('$destination.part.etag').readAsStringSync(), '"etag-1"');

    final written = <int>[];
    final result = await downloadToFile(
      bundle,
      'song.ogg',
      destination,
      onProgress: (p) => written.add(p.written),
    );
    expect(result.bytes, 200000);
    expect(File(destination).readAsBytesSync(), plain);
    expect(File('$destination.part').existsSync(), isFalse);
    expect(File('$destination.part.etag').existsSync(), isFalse);
    // Header, then from segment 1: nothing of segment 0 fetched again.
    expect(cdn.requests.last.range, 'bytes=65536-200167');
    expect(written.first, 130968);
  });

  test('a part of another object starts over', () async {
    final cdn = FakeCdn();
    final bundle = AssetBundleClient(
      AssetBundleClientOptions(baseUrl: base, key: key.text, client: cdn),
    );
    final plain = pattern(100000, 3);
    cdn.serve('${base}a.bin', encryptAsset(key.bytes, 'a.bin', plain));
    final destination = '${dir.path}/a.bin';
    File('$destination.part').writeAsBytesSync(Uint8List(70000));
    File('$destination.part.etag').writeAsStringSync('"stale"');
    File(destination).writeAsBytesSync(<int>[1, 2, 3]);
    await downloadToFile(bundle, 'a.bin', destination);
    expect(File(destination).readAsBytesSync(), plain);
  });

  test('a part without its ETag is discarded', () async {
    final cdn = FakeCdn();
    final bundle = AssetBundleClient(
      AssetBundleClientOptions(baseUrl: base, client: cdn),
    );
    final plain = pattern(5000);
    cdn.serve('${base}p', plain);
    final destination = '${dir.path}/p';
    File('$destination.part').writeAsBytesSync(Uint8List(4000));
    await downloadToFile(bundle, 'p', destination);
    expect(File(destination).readAsBytesSync(), plain);
    expect(cdn.requests.single.range, isNull);
  });

  test('creates the destination folder, as a manifest path needs', () async {
    final cdn = FakeCdn();
    final bundle = AssetBundleClient(
      AssetBundleClientOptions(baseUrl: base, key: key.text, client: cdn),
    );
    final plain = pattern(1000);
    cdn.serve(
      '${base}data/songs-3f9a.db',
      encryptAsset(key.bytes, 'data/songs-3f9a.db', plain),
    );
    final destination = '${dir.path}/data/songs-3f9a.db';
    await downloadToFile(bundle, 'data/songs-3f9a.db', destination);
    expect(File(destination).readAsBytesSync(), plain);
  });

  test(
    'a reset drops the old ETag before a byte of the new object lands',
    () async {
      final cdn = FakeCdn();
      final bundle = AssetBundleClient(
        AssetBundleClientOptions(baseUrl: base, key: key.text, client: cdn),
      );
      cdn.serve(
        '${base}a.bin',
        encryptAsset(key.bytes, 'a.bin', pattern(100000)),
      );
      final destination = '${dir.path}/a.bin';
      File('$destination.part').writeAsBytesSync(Uint8List(70000));
      File('$destination.part.etag').writeAsStringSync('"stale"');
      String? etagAtFirstWrite;
      await downloadToFile(
        bundle,
        'a.bin',
        destination,
        onProgress: (_) {
          etagAtFirstWrite ??= File('$destination.part.etag').existsSync()
              ? File('$destination.part.etag').readAsStringSync()
              : null;
        },
      );
      expect(etagAtFirstWrite, '"etag-1"');
    },
  );

  test(
    'a side file that is a link is replaced, its target untouched',
    () async {
      final cdn = FakeCdn();
      final bundle = AssetBundleClient(
        AssetBundleClientOptions(baseUrl: base, client: cdn),
      );
      final plain = pattern(500);
      cdn.serve('${base}p', plain);
      final target = File('${dir.path}/precious')..writeAsStringSync('keep');
      final destination = '${dir.path}/p';
      Link('$destination.part').createSync(target.path);
      await downloadToFile(bundle, 'p', destination);
      expect(target.readAsStringSync(), 'keep');
      expect(File(destination).readAsBytesSync(), plain);
    },
  );

  test(
    'a part longer than the file it resumes is discarded and redone',
    () async {
      final cdn = FakeCdn();
      final bundle = AssetBundleClient(
        AssetBundleClientOptions(baseUrl: base, key: key.text, client: cdn),
      );
      final plain = pattern(1000);
      final etag = cdn.serve('${base}s', encryptAsset(key.bytes, 's', plain));
      final destination = '${dir.path}/s';
      File('$destination.part').writeAsBytesSync(Uint8List(5000));
      File('$destination.part.etag').writeAsStringSync(etag);
      await downloadToFile(bundle, 's', destination);
      expect(File(destination).readAsBytesSync(), plain);
      expect(File('$destination.part').existsSync(), isFalse);
    },
  );

  test('an ArgumentError from onProgress keeps the resumable part', () async {
    final cdn = FakeCdn();
    final bundle = AssetBundleClient(
      AssetBundleClientOptions(baseUrl: base, key: key.text, client: cdn),
    );
    final plain = pattern(200000);
    final etag = cdn.serve('${base}r', encryptAsset(key.bytes, 'r', plain));
    final destination = '${dir.path}/r';
    File('$destination.part')
        .writeAsBytesSync(Uint8List.sublistView(plain, 0, 65464));
    File('$destination.part.etag').writeAsStringSync(etag);
    await expectLater(
      downloadToFile(
        bundle,
        'r',
        destination,
        onProgress: (_) => throw ArgumentError('user cancelled'),
      ),
      throwsA(isA<ArgumentError>()),
    );
    // One more verified segment landed before the callback threw; nothing
    // was truncated, and the ETag stays for the next call.
    expect(File('$destination.part').lengthSync(), 130968);
    expect(File('$destination.part.etag').readAsStringSync(), etag);
  });

  test('a path the bundle would refuse touches nothing on disk', () async {
    final bundle = AssetBundleClient(
      AssetBundleClientOptions(baseUrl: base, client: FakeCdn()),
    );
    final destination = '${dir.path}/deep/x';
    await expectLater(
      downloadToFile(bundle, '../x', destination),
      throwsA(isA<ArgumentError>()),
    );
    expect(Directory('${dir.path}/deep').existsSync(), isFalse);
  });
}
