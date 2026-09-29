// Drives the fake's `/assets/*` CDN with a raw dart:io HttpClient, so it is
// tested against what CloudFront answers, not against the asset client.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

final class Got {
  Got(this.status, this.headers, this.bytes);
  final int status;
  final HttpHeaders headers;
  final Uint8List bytes;
}

Uint8List bytesOf(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 7) & 0xff));

void main() {
  late FakeGateway gw;
  late HttpClient http;
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  final plain = bytesOf(1000);
  final secret = utf8.encode('{"v":1}');

  setUp(() async {
    gw = await FakeGateway.start(
      options: FakeGatewayOptions(
        assetBundles: <FakeAssetBundle>[
          FakeAssetBundle(
            id: 'ab_plain',
            files: <String, List<int>>{
              'data.bin': plain,
              'empty.bin': <int>[],
              'sub dir/한글 +.txt': utf8.encode('odd path'),
            },
          ),
          FakeAssetBundle(
            id: 'ab_enc',
            key: key,
            files: <String, List<int>>{'dir/manifest.json': secret},
          ),
        ],
      ),
    );
    http = HttpClient();
  });

  tearDown(() async {
    http.close();
    await gw.shutdown();
  });

  Future<Got> call(
    String path, {
    String method = 'GET',
    Map<String, String> headers = const <String, String>{},
  }) async {
    final request = await http.openUrl(method, gw.assetsUrl.resolve(path));
    headers.forEach(request.headers.set);
    final response = await request.close();
    final chunks = BytesBuilder();
    await for (final chunk in response) {
      chunks.add(chunk);
    }
    return Got(response.statusCode, response.headers, chunks.takeBytes());
  }

  test('a whole object, and HEAD with the same headers and no body', () async {
    expect(gw.assetsUrl.toString(), endsWith('/assets/'));
    final got = await call('ab_plain/data.bin');
    expect(got.status, 200);
    expect(got.bytes, plain);
    expect(got.headers.value('accept-ranges'), 'bytes');
    expect(got.headers.value('etag'), matches(RegExp(r'^"[0-9a-f]{32}"$')));
    expect(got.headers.contentLength, 1000);
    final head = await call('ab_plain/data.bin', method: 'HEAD');
    expect(head.status, 200);
    expect(head.bytes, isEmpty);
    expect(head.headers.contentLength, 1000);
    expect(head.headers.value('etag'), got.headers.value('etag'));
  });

  test('one range in each form; 416 past the end', () async {
    Future<void> expectRange(String range, int start, int end) async {
      final got = await call(
        'ab_plain/data.bin',
        headers: <String, String>{'range': range},
      );
      expect(got.status, 206, reason: range);
      expect(
        got.headers.value('content-range'),
        'bytes $start-${end - 1}/1000',
        reason: range,
      );
      expect(got.bytes, plain.sublist(start, end), reason: range);
    }

    await expectRange('bytes=0-9', 0, 10);
    await expectRange('bytes=990-', 990, 1000);
    await expectRange('bytes=995-5000', 995, 1000);
    await expectRange('bytes=-4', 996, 1000);
    await expectRange('bytes=-5000', 0, 1000);
    for (final range in <String>['bytes=1000-', 'bytes=-0']) {
      final past = await call(
        'ab_plain/data.bin',
        headers: <String, String>{'range': range},
      );
      expect(past.status, 416, reason: range);
      expect(past.headers.value('content-range'), 'bytes */1000');
    }
    for (final ignored in <String>['bytes=5-2', 'bytes=0-1,4-5', 'items=0-1']) {
      final whole = await call(
        'ab_plain/data.bin',
        headers: <String, String>{'range': ignored},
      );
      expect(whole.status, 200, reason: ignored);
      expect(whole.bytes, hasLength(1000), reason: ignored);
    }
  });

  test('If-Range: the range only while the ETag still matches', () async {
    final etag = (await call(
      'ab_plain/data.bin',
      method: 'HEAD',
    )).headers.value('etag')!;
    final same = await call(
      'ab_plain/data.bin',
      headers: <String, String>{'range': 'bytes=0-9', 'if-range': etag},
    );
    expect(same.status, 206);
    final other = await call(
      'ab_plain/data.bin',
      headers: <String, String>{'range': 'bytes=0-9', 'if-range': '"x"'},
    );
    expect(other.status, 200);
    expect(other.bytes, hasLength(1000));
    final alone = await call(
      'ab_plain/data.bin',
      headers: <String, String>{'if-range': etag},
    );
    expect(alone.status, 200, reason: 'If-Range without Range');
    expect(alone.bytes, hasLength(1000));
  });

  test('an empty object, an encoded path, a repeated header', () async {
    final empty = await call('ab_plain/empty.bin');
    expect(empty.status, 200);
    expect(empty.bytes, isEmpty);
    final suffix = await call(
      'ab_plain/empty.bin',
      headers: <String, String>{'range': 'bytes=-1'},
    );
    expect(suffix.status, 416);
    expect(suffix.headers.value('content-range'), 'bytes */0');
    final odd = await call(
      'ab_plain/${Uri.encodeComponent('sub dir')}/'
      '${Uri.encodeComponent('한글 +.txt')}',
    );
    expect(odd.status, 200);
    expect(utf8.decode(odd.bytes), 'odd path');
    // Two Range lines: dart:io's client would fold them into one, so the
    // request is written by hand.
    final socket = await Socket.connect(gw.assetsUrl.host, gw.assetsUrl.port);
    socket.write(
      'GET /assets/ab_plain/data.bin HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      'Range: bytes=0-1\r\n'
      'Range: bytes=2-3\r\n'
      'Connection: close\r\n\r\n',
    );
    final reply = await utf8.decoder.bind(socket).join();
    expect(reply, startsWith('HTTP/1.1 400'));
  });

  test('the store serves its own copy of the bytes', () async {
    final bundle = FakeAssetBundle(
      id: 'ab_copy',
      files: <String, List<int>>{
        'a': <int>[1, 2, 3],
      },
    );
    expect(() => bundle.objects['b'] = Uint8List(0), throwsUnsupportedError);
    final own = await FakeGateway.start(
      options: FakeGatewayOptions(assetBundles: <FakeAssetBundle>[bundle]),
    );
    addTearDown(own.shutdown);
    bundle.objects['a']![0] = 9;
    final request = await http.openUrl(
      'GET',
      own.assetsUrl.resolve('ab_copy/a'),
    );
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    expect(bytes, <int>[1, 2, 3]);
  });

  test('a missing object or bundle is 403; only GET and HEAD', () async {
    expect((await call('ab_plain/nope.bin')).status, 403);
    expect((await call('ab_none/data.bin')).status, 403);
    expect((await call('ab_plain/data.bin', method: 'POST')).status, 405);
  });

  test('an encrypted bundle serves yyt-enc v1 bound to the path', () async {
    final got = await call('ab_enc/dir/manifest.json');
    expect(got.status, 200);
    expect(got.bytes, encryptAsset(key, 'dir/manifest.json', secret));
    expect(got.bytes.first, 0x28, reason: 'the format header');
    // 40 header bytes, the ciphertext, one 32-byte tag.
    expect(got.bytes, hasLength(40 + secret.length + 32));
    expect(
      encryptAsset(key, 'other.json', secret),
      isNot(got.bytes),
      reason: 'the path is the associated data',
    );
  });

  test('assetKeyText is the yak1 form of 32 bytes', () {
    final text = assetKeyText(key);
    expect(text, startsWith('yak1.'));
    expect(text, hasLength(5 + 43));
    expect(text, isNot(contains('=')));
    expect(base64Url.decode('${text.substring(5)}='), key);
    expect(
      () => assetKeyText(Uint8List(31)),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'an asset key is 32 bytes',
        ),
      ),
    );
  });
}
