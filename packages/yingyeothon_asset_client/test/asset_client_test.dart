import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_asset_client/yingyeothon_asset_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'support/encrypt.dart';
import 'support/fake_cdn.dart';

const String base = 'https://dev-d.yyt.life/assets/ab_test/';
final key = testKey(3);
final otherKey = testKey(99);

/// The interesting lengths: segment boundaries of `yyt-enc v1`.
const List<int> lengths = <int>[
  0,
  1,
  65463,
  65464,
  65465,
  130968,
  130969,
  131100,
  200000,
];

Matcher failsWith(String code, [int? status]) => throwsA(
  isA<AssetClientException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.status, 'status', status ?? anything),
);

final class Setup {
  Setup({
    bool crossOrigin = false,
    bool ignoreRange = false,
    bool ignoreIfRange = false,
    bool noEtag = false,
    void Function(int, Recorded)? beforeAnswer,
    Object? clientKey,
    String baseUrl = base,
    Logger? logger,
  }) : cdn = FakeCdn(
         crossOrigin: crossOrigin,
         ignoreRange: ignoreRange,
         ignoreIfRange: ignoreIfRange,
         noEtag: noEtag,
         beforeAnswer: beforeAnswer,
       ) {
    client = AssetBundleClient(
      AssetBundleClientOptions(
        baseUrl: baseUrl,
        key: clientKey ?? key.text,
        corsSafe: crossOrigin,
        client: cdn,
        logger: logger,
      ),
    );
  }

  final FakeCdn cdn;
  late AssetBundleClient client;

  /// Encrypts [plain] at [path] (AD = [ad] or the path) and serves it.
  String serve(String path, Uint8List plain, {String? ad, String url = base}) =>
      cdn.serve(
        url + path.split('/').map(Uri.encodeComponent).join('/'),
        encryptAsset(key.bytes, ad ?? path, plain),
      );
}

final class Lines implements LogWriter {
  final List<String> lines = <String>[];
  void _add(LogSeverity s, String m, Map<String, Object?>? c) =>
      lines.add(LogWriters.format(s, m, c));
  @override
  void debug(String message, [Map<String, Object?>? context]) =>
      _add(LogSeverity.debug, message, context);
  @override
  void info(String message, [Map<String, Object?>? context]) =>
      _add(LogSeverity.info, message, context);
  @override
  void warn(String message, [Map<String, Object?>? context]) =>
      _add(LogSeverity.warn, message, context);
  @override
  void error(String message, [Map<String, Object?>? context]) =>
      _add(LogSeverity.error, message, context);
}

void main() {
  group('construction', () {
    test('takes the key as text or as 32 raw bytes', () async {
      final plain = pattern(1000);
      for (final k in <Object>[key.text, Uint8List.fromList(key.bytes)]) {
        final s = Setup(clientKey: k);
        s.serve('a.bin', plain);
        expect(await s.client.read('a.bin'), plain);
      }
    });

    test('refuses every text that is not the canonical yak1 form, quoting '
        'none of it', () {
      final body = key.text.substring(5);
      for (final bad in <Object>[
        '',
        body,
        'yak2.$body',
        'yak1.${body}A',
        'yak1.${body.substring(1)}',
        'yak1.${body.substring(0, 42)}=',
        'yak1.${body.replaceAll('-', '+').replaceAll('_', '/')}x',
        Uint8List(31),
        Uint8List(33),
        42,
      ]) {
        try {
          AssetBundleClient(AssetBundleClientOptions(baseUrl: base, key: bad));
          fail('accepted a bad key');
        } on AssetClientException catch (e) {
          expect(e.code, AssetClientErrorCode.badKey);
          expect(e.toString(), 'AssetClientException(bad_key, status 0)');
        }
      }
    });

    test('accepts exactly the 16 canonical last characters', () {
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
      final stem = key.text.substring(0, key.text.length - 1);
      final accepted = <String>[];
      for (final last in alphabet.split('')) {
        try {
          AssetBundleClient(
            AssetBundleClientOptions(baseUrl: base, key: '$stem$last'),
          ).close();
          accepted.add(last);
        } on AssetClientException {
          // Refused: a non-canonical encoding of some key.
        }
      }
      expect(accepted, hasLength(16));
      expect(accepted.every('AEIMQUYcgkosw048'.contains), isTrue);
    });

    test('checks baseUrl and paths before any request, quoting neither', () {
      final s = Setup();
      for (final bad in <String>[
        'not a url',
        'ftp://d.example/assets/b/',
        'https://user:pw@d.example/assets/b/',
        'https://d.example/assets/b/?q=1',
        'https://d.example/assets/b/#f',
        // Encrypted: neither the bundle nor a version.
        'https://d.example/assets/',
        'https://d.example/elsewhere/b/',
        'https://d.example/assets/b/v1/music/',
      ]) {
        expect(
          () => AssetBundleClient(
            AssetBundleClientOptions(baseUrl: bad, key: key.text),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              isNot(contains(bad.length > 12 ? bad.substring(8) : bad)),
            ),
          ),
          reason: bad,
        );
      }
      // A plain bundle may live anywhere http(s).
      AssetBundleClient(
        AssetBundleClientOptions(baseUrl: 'https://d.example/anything/'),
      ).close();
      for (final bad in <String>[
        '',
        '/a',
        'a/',
        'a//b',
        './a',
        'a/../b',
        'a\\b',
        'a\u0001b',
        'a\uD800b',
      ]) {
        expect(
          () => s.client.read(bad),
          throwsA(isA<ArgumentError>()),
          reason: bad,
        );
      }
      expect(s.cdn.requests, isEmpty);
    });

    test('corsSafe defaults to true on web and false elsewhere', () {
      expect(
        const AssetBundleClientOptions(baseUrl: base).effectiveCorsSafe,
        const bool.fromEnvironment('dart.library.js_interop'),
      );
      expect(
        const AssetBundleClientOptions(
          baseUrl: base,
          corsSafe: true,
        ).effectiveCorsSafe,
        isTrue,
      );
    });
  });

  for (final crossOrigin in <bool>[false, true]) {
    final mode = crossOrigin ? 'browser mode' : 'conditional mode';

    group('read, $mode', () {
      test('every length round-trips, in one request', () async {
        final s = Setup(crossOrigin: crossOrigin);
        for (final n in lengths) {
          final plain = pattern(n, n);
          s.serve('f$n', plain);
          expect(await s.client.read('f$n'), plain, reason: '$n');
        }
        expect(s.cdn.requests, hasLength(lengths.length));
        expect(s.cdn.requests.every((r) => r.range == null), isTrue);
        expect(s.cdn.openBodies, 0);
      });

      test(
        'binds the version below the bundle and the raw UTF-8 path',
        () async {
          const versioned = '${base}v3/';
          final s = Setup(crossOrigin: crossOrigin, baseUrl: versioned);
          final plain = pattern(70000);
          s.serve('데이터/노래 1.db', plain, ad: 'v3/데이터/노래 1.db', url: versioned);
          expect(await s.client.read('데이터/노래 1.db'), plain);
          expect(
            s.cdn.requests.single.url,
            '$versioned${Uri.encodeComponent('데이터')}/'
            '${Uri.encodeComponent('노래 1.db')}',
          );
          // The same bytes under another version fail like a wrong key.
          s.cdn.serve('${versioned}x', encryptAsset(key.bytes, 'x', plain));
          await expectLater(
            s.client.read('x'),
            failsWith(AssetClientErrorCode.assetCorrupt),
          );
        },
      );

      test('a range is fetched as the covered segments only', () async {
        final s = Setup(crossOrigin: crossOrigin);
        final plain = pattern(200000);
        s.serve('big', plain);
        expect(
          await s.client.readRange('big', start: 140000, end: 140010),
          Uint8List.sublistView(plain, 140000, 140010),
        );
        // Header, then segment 2 alone (bytes 131072-196607).
        expect(
          s.cdn.requests.map((r) => '${r.method} ${r.range}').toList(),
          <String>[
            if (crossOrigin) 'HEAD null',
            'GET bytes=0-39',
            'GET bytes=131072-196607',
          ],
        );
        expect(s.cdn.openBodies, 0);
      });

      test(
        'a range in segment 0 arrives with the header, in one GET',
        () async {
          final s = Setup(crossOrigin: crossOrigin);
          final plain = pattern(200000);
          s.serve('big', plain);
          expect(
            await s.client.readRange('big', start: 10, end: 20),
            Uint8List.sublistView(plain, 10, 20),
          );
          expect(
            s.cdn.requests.where((r) => r.method == 'GET').single.range,
            'bytes=0-65535',
          );
        },
      );

      test('starts over when the object changes between requests', () async {
        final newer = pattern(200000, 1);
        late Setup s;
        s = Setup(
          crossOrigin: crossOrigin,
          beforeAnswer: (i, r) {
            if (i == (crossOrigin ? 2 : 1)) s.serve('big', newer);
          },
        );
        s.serve('big', pattern(200000, 2));
        expect(
          await s.client.readRange('big', start: 140000, end: 140100),
          Uint8List.sublistView(newer, 140000, 140100),
        );
        expect(s.cdn.openBodies, 0);
      });

      test('gives up with http after three restarts', () async {
        late Setup s;
        var n = 0;
        s = Setup(
          crossOrigin: crossOrigin,
          // Every attempt: the object changes right before its segments.
          beforeAnswer: (i, r) {
            if (r.range?.startsWith('bytes=131072') ?? false) {
              s.serve('big', pattern(200000, ++n));
            }
          },
        );
        s.serve('big', pattern(200000));
        await expectLater(
          s.client.readRange('big', start: 140000, end: 140001),
          failsWith(AssetClientErrorCode.http),
        );
        // Four attempts: the first and three restarts.
        expect(
          s.cdn.requests.where(
            (r) => r.range?.startsWith('bytes=131072') ?? false,
          ),
          hasLength(4),
        );
        expect(s.cdn.openBodies, 0);
      });

      test('is http when the host ignores Range', () async {
        final s = Setup(crossOrigin: crossOrigin, ignoreRange: true);
        s.serve('big', pattern(200000));
        await expectLater(
          s.client.readRange('big', start: 140000, end: 140001),
          failsWith(AssetClientErrorCode.http, 200),
        );
        expect(s.cdn.openBodies, 0);
      });

      test('still verifies without an ETag', () async {
        final s = Setup(crossOrigin: crossOrigin, noEtag: true);
        final plain = pattern(140000);
        s.serve('f', plain);
        expect(
          await s.client.readRange('f', start: 70000),
          Uint8List.sublistView(plain, 70000),
        );
      });

      test(
        'a missing object is not_found, and a bad window is local',
        () async {
          final s = Setup(crossOrigin: crossOrigin);
          await expectLater(
            s.client.readRange('nope', start: 0, end: 1),
            failsWith(AssetClientErrorCode.notFound, 403),
          );
          final before = s.cdn.requests.length;
          expect(await s.client.readRange('nope', start: 5, end: 5), isEmpty);
          expect(await s.client.readRange('nope', start: 5, end: 1), isEmpty);
          expect(
            () => s.client.readRange('nope', start: -1),
            throwsA(isA<ArgumentError>()),
          );
          expect(s.cdn.requests, hasLength(before));
        },
      );
    });

    group('download, $mode', () {
      test('writes verified segments and reports progress', () async {
        final s = Setup(crossOrigin: crossOrigin);
        final plain = pattern(200000);
        final etag = s.serve('big', plain);
        final sink = MemorySink();
        final progress = <int>[];
        final result = await s.client.download(
          'big',
          sink: sink,
          onProgress: (p) {
            progress.add(p.written);
            expect(p.total, 200000);
            expect(p.etag, etag);
          },
        );
        expect(sink.bytes, plain);
        expect(result.bytes, 200000);
        expect(result.etag, etag);
        expect(progress, <int>[65464, 130968, 196472, 200000]);
        expect(s.cdn.openBodies, 0);
      });

      test('resumes from the segment holding the offset', () async {
        final s = Setup(crossOrigin: crossOrigin);
        final plain = pattern(200000);
        final etag = s.serve('big', plain);
        final sink = MemorySink()
          ..seed(Uint8List.sublistView(plain, 0, 140000));
        await s.client.download(
          'big',
          sink: sink,
          resume: AssetResume(offset: 140000, etag: etag),
        );
        expect(sink.bytes, plain);
        expect(sink.events.first, 'write:${196472 - 140000}');
        // Segment 2 to the end of the 200,168-byte ciphertext.
        expect(s.cdn.requests.last.range, 'bytes=131072-200167');
      });

      test('starts over, resetting the sink, for another object', () async {
        final s = Setup(crossOrigin: crossOrigin);
        final plain = pattern(100000);
        s.serve('f', plain);
        final sink = MemorySink()..seed(pattern(70000, 9));
        await s.client.download(
          'f',
          sink: sink,
          resume: const AssetResume(offset: 70000, etag: '"stale"'),
        );
        expect(sink.events.first, 'reset');
        expect(sink.bytes, plain);
      });

      test(
        'an already complete resume verifies the last segment only',
        () async {
          final s = Setup(crossOrigin: crossOrigin);
          final plain = pattern(100000);
          final etag = s.serve('f', plain);
          final sink = MemorySink();
          final reports = <AssetDownloadProgress>[];
          final result = await s.client.download(
            'f',
            sink: sink,
            resume: AssetResume(offset: 100000, etag: etag),
            onProgress: reports.add,
          );
          expect(sink.events, isEmpty);
          expect(result.bytes, 100000);
          expect(reports.single.written, 100000);
        },
      );

      test(
        'an offset past the end is an ArgumentError once verified',
        () async {
          final s = Setup(crossOrigin: crossOrigin);
          final etag = s.serve('f', pattern(100));
          await expectLater(
            s.client.download(
              'f',
              sink: MemorySink(),
              resume: AssetResume(offset: 101, etag: etag),
            ),
            throwsA(isA<ArgumentError>()),
          );
          expect(
            () => s.client.download(
              'f',
              sink: MemorySink(),
              resume: const AssetResume(offset: 1, etag: ''),
            ),
            throwsA(isA<ArgumentError>()),
          );
        },
      );

      test('writes nothing of a segment whose tag fails', () async {
        final s = Setup(crossOrigin: crossOrigin);
        final bytes = encryptAsset(key.bytes, 'f', pattern(100000));
        bytes[70000] ^= 1; // inside segment 1
        s.cdn.serve('${base}f', bytes);
        final sink = MemorySink();
        await expectLater(
          s.client.download('f', sink: sink),
          failsWith(AssetClientErrorCode.assetCorrupt),
        );
        expect(sink.events, <String>['write:65464']);
        expect(s.cdn.openBodies, 0);
      });

      test("a sink's own failure passes through unchanged", () async {
        final s = Setup(crossOrigin: crossOrigin);
        s.serve('f', pattern(100000));
        final boom = StateError('disk full');
        await expectLater(
          s.client.download('f', sink: _ThrowingSink(boom)),
          throwsA(same(boom)),
        );
        expect(s.cdn.openBodies, 0);
      });
    });
  }

  group('read failures', () {
    test('tampering is asset_corrupt, and a bad length is refused before '
        'the body', () async {
      final s = Setup();
      final good = encryptAsset(key.bytes, 'f', pattern(100000));
      for (final bad in <Uint8List>[
        Uint8List.fromList(good)..[100] ^= 1,
        Uint8List.fromList(good)..[good.length - 1] ^= 1,
        Uint8List.sublistView(good, 0, good.length - 1),
        Uint8List.fromList(<int>[...good, 0]),
      ]) {
        s.cdn.serve('${base}f', bad);
        await expectLater(
          s.client.read('f'),
          failsWith(AssetClientErrorCode.assetCorrupt),
        );
      }
      // 65,537 + 33 − 1 bytes: the last segment would hold no plaintext.
      s.cdn.serve('${base}g', Uint8List(65536 + 32));
      await expectLater(
        s.client.read('g'),
        failsWith(AssetClientErrorCode.assetCorrupt, 200),
      );
      expect(s.cdn.openBodies, 0);
    });

    test('403 and 404 are not_found, other statuses http, a throw network, '
        'quoting nothing', () async {
      final s = Setup();
      for (final (status, code) in <(int, String)>[
        (403, AssetClientErrorCode.notFound),
        (404, AssetClientErrorCode.notFound),
        (500, AssetClientErrorCode.http),
        (304, AssetClientErrorCode.http),
      ]) {
        s.cdn.forceStatus = status;
        await expectLater(s.client.read('f'), failsWith(code, status));
      }
      s.cdn
        ..forceStatus = null
        ..failWith = http.ClientException(
          'Connection refused: $base/f',
          Uri.parse('${base}f'),
        );
      try {
        await s.client.read('f');
        fail('read succeeded');
      } on AssetClientException catch (e) {
        expect(e.toString(), 'AssetClientException(network, status 0)');
      }
      expect(s.cdn.openBodies, 0);
    });

    test('a body that fails mid-transfer is network', () async {
      final client = _FailingBodyClient();
      final bundle = AssetBundleClient(
        AssetBundleClientOptions(baseUrl: base, key: key.text, client: client),
      );
      await expectLater(
        bundle.read('f'),
        failsWith(AssetClientErrorCode.network, 200),
      );
    });

    test('noCache is sent only outside a browser', () async {
      for (final crossOrigin in <bool>[false, true]) {
        final s = Setup(crossOrigin: crossOrigin);
        s.serve('f', pattern(10));
        await s.client.read('f', noCache: true);
        await s.client.read('f');
        expect(
          s.cdn.requests.map((r) => r.headers['cache-control']).toList(),
          <String?>[if (!crossOrigin) 'no-cache' else null, null],
        );
      }
    });

    test(
      'close() refuses later reads and releases only its own client',
      () async {
        final s = Setup();
        s.serve('f', pattern(10));
        s.client.close();
        s.client.close();
        expect(() => s.client.read('f'), throwsA(isA<StateError>()));
        // The injected client is still usable.
        expect((await s.cdn.get(Uri.parse('${base}f'))).statusCode, 200);
      },
    );

    test('close() stops a read in flight at its next segment', () async {
      final s = Setup();
      s.serve('big', pattern(200000));
      final sink = _ClosingSink(s.client);
      await expectLater(
        s.client.download('big', sink: sink),
        throwsA(isA<StateError>()),
      );
      expect(sink.writes, 1, reason: 'the second segment never reached it');
      expect(s.cdn.openBodies, 0);
    });

    test(
      'close() with the default client ends a read as StateError too',
      () async {
        // Not injected: close() also closes this client, which errors the
        // body under the read.
        final cdn = FakeCdn();
        cdn.serve(
          '${base}big',
          encryptAsset(key.bytes, 'big', pattern(200000)),
        );
        final owned = _Owned(cdn);
        final client = AssetBundleClient(
          AssetBundleClientOptions(baseUrl: base, key: key.text, client: owned),
        );
        final sink = _ClosingSink(client);
        await expectLater(
          client.download('big', sink: sink),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'a body that stalls ends as network; closed meanwhile, StateError',
      () async {
        for (final closeFirst in <bool>[false, true]) {
          final client = AssetBundleClient(
            AssetBundleClientOptions(
              baseUrl: base,
              corsSafe: false,
              client: _StallingClient(),
              bodyIdleTimeout: const Duration(milliseconds: 50),
            ),
          );
          final read = client.read('f');
          if (closeFirst) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            client.close();
          }
          await expectLater(
            read,
            closeFirst
                ? throwsA(isA<StateError>())
                : failsWith(AssetClientErrorCode.network, 200),
          );
        }
      },
    );

    test('headers that never come end as network, with any client', () async {
      final client = AssetBundleClient(
        AssetBundleClientOptions(
          baseUrl: base,
          client: _SilentClient(),
          responseTimeout: const Duration(milliseconds: 50),
        ),
      );
      try {
        await client.read('f');
        fail('read');
      } on AssetClientException catch (e) {
        expect(e.code, AssetClientErrorCode.network);
        expect(e.detail, 'no response in time');
      }
    });

    test(
      'a plain body larger than any asset is http, even without a length',
      () async {
        final client = AssetBundleClient(
          AssetBundleClientOptions(
            baseUrl: base,
            corsSafe: true,
            client: _EndlessClient(),
          ),
        );
        final sink = _CountingSink();
        await expectLater(
          client.download('f', sink: sink),
          failsWith(AssetClientErrorCode.http, 200),
        );
        expect(sink.bytes, lessThanOrEqualTo(268566664));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('readJson', () {
    test('parses UTF-8 JSON', () async {
      final s = Setup();
      s.serve('m.json', Uint8List.fromList(utf8.encode('{"v":[1,"둘"]}')));
      expect(await s.client.readJson('m.json'), <String, Object?>{
        'v': <Object?>[1, '둘'],
      });
    });

    test(
      'is asset_corrupt on bytes that are not UTF-8 JSON, quoting none',
      () async {
        final s = Setup();
        for (final bad in <List<int>>[
          utf8.encode('{"secret": '),
          <int>[0xff, 0xfe, 0x7b],
          utf8.encode('secret'),
        ]) {
          s.serve('m.json', Uint8List.fromList(bad));
          try {
            await s.client.readJson('m.json');
            fail('parsed');
          } on AssetClientException catch (e) {
            expect(
              e.toString(),
              'AssetClientException(asset_corrupt, status 0)',
            );
          }
        }
      },
    );
  });

  group('readRange, odd hosts', () {
    test('a 206 without a numeric total is http', () async {
      final s = Setup(clientKey: key.text);
      s.serve('big', pattern(200000));
      final client = AssetBundleClient(
        AssetBundleClientOptions(
          baseUrl: base,
          key: key.text,
          client: _RewritingClient(s.cdn, (h) {
            final range = h['content-range'];
            if (range != null) {
              h['content-range'] = range.replaceAll(RegExp(r'/\d+$'), '/*');
            }
          }),
        ),
      );
      await expectLater(
        client.readRange('big', start: 140000, end: 140001),
        failsWith(AssetClientErrorCode.http, 206),
      );
    });

    test('an empty object is asset_corrupt (416 before any length)', () async {
      final s = Setup();
      s.cdn.serve('${base}empty', Uint8List(0));
      await expectLater(
        s.client.readRange('empty', start: 0),
        failsWith(AssetClientErrorCode.assetCorrupt, 416),
      );
    });

    test('a ranged body that ends early is network', () async {
      final s = Setup();
      s.serve('big', pattern(200000));
      final client = AssetBundleClient(
        AssetBundleClientOptions(
          baseUrl: base,
          key: key.text,
          client: _TruncatingClient(s.cdn, 1000),
        ),
      );
      await expectLater(
        client.readRange('big', start: 140000, end: 140001),
        failsWith(AssetClientErrorCode.network, 206),
      );
    });

    test('a browser that refuses Range falls back to one whole GET', () async {
      final lines = Lines();
      final s = Setup(
        crossOrigin: true,
        logger: createFilteredLogger(
          severity: LogSeverity.debug,
          writer: lines,
        ),
      );
      final plain = pattern(200000);
      s.serve('big', plain);
      s.cdn.refuseRange();
      expect(
        await s.client.readRange('big', start: 140000, end: 140005),
        Uint8List.sublistView(plain, 140000, 140005),
      );
      expect(s.cdn.requests.map((r) => r.method).toList(), <String>[
        'HEAD',
        'GET',
        'GET',
      ]);
      expect(
        lines.lines,
        contains(
          startsWith('[warn] asset ranged request refused; reading the whole'),
        ),
      );
      expect(s.cdn.openBodies, 0);
    });

    test(
      'outside a browser a refused request is network, no fallback',
      () async {
        final s = Setup();
        s.serve('big', pattern(200000));
        s.cdn.refuseRange();
        await expectLater(
          s.client.readRange('big', start: 140000, end: 140005),
          failsWith(AssetClientErrorCode.network, 0),
        );
        expect(s.cdn.requests, hasLength(1));
      },
    );
  });

  group('a plain bundle', () {
    Setup plainSetup({bool crossOrigin = false, bool ignoreRange = false}) {
      final s = Setup(crossOrigin: crossOrigin, ignoreRange: ignoreRange);
      s.client.close();
      s.client = AssetBundleClient(
        AssetBundleClientOptions(
          baseUrl: base,
          corsSafe: crossOrigin,
          client: s.cdn,
        ),
      );
      return s;
    }

    test('reads, reads JSON and reads ranges with the same calls', () async {
      final s = plainSetup();
      final plain = pattern(1000);
      s.cdn
        ..serve('${base}p', plain)
        ..serve('${base}m.json', Uint8List.fromList(utf8.encode('[1]')));
      expect(await s.client.read('p'), plain);
      expect(await s.client.readJson('m.json'), <Object?>[1]);
      expect(
        await s.client.readRange('p', start: 10, end: 20),
        Uint8List.sublistView(plain, 10, 20),
      );
      expect(await s.client.readRange('p', start: 2000), isEmpty);
      expect(s.cdn.requests.last.range, 'bytes=2000-');
    });

    test('slices the whole file when the host ignores Range', () async {
      final s = plainSetup(ignoreRange: true);
      final plain = pattern(1000);
      s.cdn.serve('${base}p', plain);
      expect(
        await s.client.readRange('p', start: 990, end: 2000),
        Uint8List.sublistView(plain, 990),
      );
    });

    test(
      'a stated range larger than any asset is http, before reading',
      () async {
        final s = plainSetup();
        s.cdn.serve('${base}p', pattern(1000));
        final client = AssetBundleClient(
          AssetBundleClientOptions(
            baseUrl: base,
            corsSafe: false,
            client: _RewritingClient(s.cdn, (h) {
              h['content-range'] = 'bytes 0-9999999999999/10000000000000';
            }),
          ),
        );
        await expectLater(
          client.readRange('p', start: 0),
          failsWith(AssetClientErrorCode.http, 206),
        );
        expect(s.cdn.openBodies, 0);
      },
    );

    test('reads a range in a browser without Content-Range', () async {
      final s = plainSetup(crossOrigin: true);
      final plain = pattern(1000);
      s.cdn.serve('${base}p', plain);
      expect(
        await s.client.readRange('p', start: 10, end: 20),
        Uint8List.sublistView(plain, 10, 20),
      );
    });

    test('downloads, resumes, and a finished resume ends on 416', () async {
      final s = plainSetup();
      final plain = pattern(1000);
      final etag = s.cdn.serve('${base}p', plain);
      final sink = MemorySink();
      expect((await s.client.download('p', sink: sink)).bytes, 1000);
      expect(sink.bytes, plain);
      final resumed = MemorySink()..seed(Uint8List.sublistView(plain, 0, 400));
      await s.client.download(
        'p',
        sink: resumed,
        resume: AssetResume(offset: 400, etag: etag),
      );
      expect(resumed.bytes, plain);
      expect(s.cdn.requests.last.range, 'bytes=400-');
      final done = MemorySink();
      final reports = <AssetDownloadProgress>[];
      await s.client.download(
        'p',
        sink: done,
        resume: AssetResume(offset: 1000, etag: etag),
        onProgress: reports.add,
      );
      expect(done.events, isEmpty);
      expect(reports.single.written, 1000);
    });

    test('an empty plain file reports progress once', () async {
      final s = plainSetup();
      s.cdn.serve('${base}e', Uint8List(0));
      final reports = <AssetDownloadProgress>[];
      await s.client.download('e', sink: MemorySink(), onProgress: reports.add);
      expect(reports, hasLength(1));
      expect(reports.single.written, 0);
    });

    test('a body shorter than its stated length is network', () async {
      final s = plainSetup();
      s.cdn.serve('${base}p', pattern(1000));
      final client = AssetBundleClient(
        AssetBundleClientOptions(
          baseUrl: base,
          corsSafe: false,
          client: _TruncatingClient(s.cdn, 10),
        ),
      );
      await expectLater(
        client.download('p', sink: MemorySink()),
        failsWith(AssetClientErrorCode.network, 200),
      );
    });
  });

  group('concurrency', () {
    test('reads on one client in parallel keep their own keys', () async {
      final s = Setup();
      final a = pattern(400000, 1);
      final b = pattern(400000, 2);
      s
        ..serve('a', a)
        ..serve('b', b);
      final results = await Future.wait(<Future<Uint8List>>[
        for (var i = 0; i < 6; i++)
          s.client.readRange(
            i.isEven ? 'a' : 'b',
            start: 1000 + i * 30000,
            end: 1000 + i * 30000 + 70000,
          ),
      ]);
      for (var i = 0; i < 6; i++) {
        final src = i.isEven ? a : b;
        final start = 1000 + i * 30000;
        expect(
          results[i],
          Uint8List.sublistView(src, start, start + 70000),
          reason: '$i',
        );
      }
      expect(s.cdn.openBodies, 0);
    });
  });

  group('restart paths', () {
    test('an encrypted object that shrinks after its length was read is a '
        'change (416), then read afresh', () async {
      late Setup s;
      final smaller = pattern(70000, 4);
      s = Setup(
        beforeAnswer: (i, r) {
          if (i == 1) s.serve('big', smaller);
        },
      );
      s.serve('big', pattern(200000));
      // Header from the first object, then its segment 2 asked of the second.
      expect(
        await s.client.readRange('big', start: 0x10000 * 2),
        isEmpty,
        reason: 'the second object ends before the window',
      );
      // The 416 was a change: the read started over from the header.
      expect(
        s.cdn.requests.where((r) => r.range == 'bytes=0-39'),
        hasLength(2),
      );
      expect(s.cdn.openBodies, 0);
    });

    test('a 206 that is not the range asked for is http', () async {
      final s = Setup();
      s.serve('big', pattern(200000));
      final client = AssetBundleClient(
        AssetBundleClientOptions(
          baseUrl: base,
          key: key.text,
          client: _RewritingClient(s.cdn, (h) {
            final range = h['content-range'];
            if (range != null && range.startsWith('bytes 131072')) {
              h['content-range'] = range.replaceFirst('131072', '131073');
            }
          }),
        ),
      );
      await expectLater(
        client.readRange('big', start: 140000, end: 140001),
        failsWith(AssetClientErrorCode.http, 206),
      );
    });

    Setup plain({
      bool crossOrigin = false,
      void Function(int, Recorded)? before,
    }) {
      final s = Setup(crossOrigin: crossOrigin, beforeAnswer: before);
      s.client.close();
      s.client = AssetBundleClient(
        AssetBundleClientOptions(
          baseUrl: base,
          corsSafe: crossOrigin,
          client: s.cdn,
        ),
      );
      return s;
    }

    test(
      'a plain resume of another object resets the sink and starts over',
      () async {
        final s = plain();
        final newer = pattern(900, 5);
        s.cdn.serve('${base}p', newer);
        final sink = MemorySink()..seed(pattern(400));
        await s.client.download(
          'p',
          sink: sink,
          resume: const AssetResume(offset: 400, etag: '"old"'),
        );
        expect(sink.events.first, 'reset');
        expect(sink.bytes, newer);
      },
    );

    test(
      'a plain resume past the end of the same object restarts from 0',
      () async {
        final s = plain();
        final plainBytes = pattern(300);
        s.cdn.serve('${base}p', plainBytes);
        final sink = MemorySink()..seed(pattern(400));
        await s.client.download(
          'p',
          sink: sink,
          resume: const AssetResume(offset: 400, etag: '"etag-1"'),
        );
        expect(sink.events.first, 'reset');
        expect(sink.bytes, plainBytes);
      },
    );

    test('a plain 206 whose ETag differs from the resumed one restarts, '
        'in a browser', () async {
      final s = plain(crossOrigin: true);
      final newer = pattern(900, 6);
      s.cdn.serve('${base}p', newer);
      final sink = MemorySink()..seed(pattern(400));
      await s.client.download(
        'p',
        sink: sink,
        resume: const AssetResume(offset: 400, etag: '"old"'),
      );
      expect(sink.events.first, 'reset');
      expect(sink.bytes, newer);
    });

    test('a browser that refuses Range reads a plain range whole', () async {
      final s = plain(crossOrigin: true);
      final plainBytes = pattern(1000);
      s.cdn.serve('${base}p', plainBytes);
      s.cdn.refuseRange();
      expect(
        await s.client.readRange('p', start: 10, end: 20),
        Uint8List.sublistView(plainBytes, 10, 20),
      );
      expect(s.cdn.requests.last.range, isNull);
    });

    test(
      'a range result does not share a buffer with the rest of the segment',
      () async {
        final s = Setup();
        s.serve('big', pattern(200000));
        final window = await s.client.readRange('big', start: 10, end: 20);
        expect(window.buffer.lengthInBytes, 10);
      },
    );

    test(
      'readJson accepts a byte-order mark, as a browser decoder does',
      () async {
        final s = Setup();
        s.serve(
          'm.json',
          Uint8List.fromList(<int>[0xef, 0xbb, 0xbf, ...utf8.encode('[2]')]),
        );
        expect(await s.client.readJson('m.json'), <Object?>[2]);
      },
    );
  });

  group('closing and logging', () {
    test(
      'close() while waiting for headers ends the read as StateError',
      () async {
        final client = AssetBundleClient(
          AssetBundleClientOptions(
            baseUrl: base,
            client: _SilentClient(),
            responseTimeout: const Duration(milliseconds: 50),
          ),
        );
        final read = client.read('f');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        client.close();
        await expectLater(read, throwsA(isA<StateError>()));
      },
    );

    test('a logged path has every invisible character replaced', () async {
      final lines = Lines();
      final s = Setup(
        logger: createFilteredLogger(
          severity: LogSeverity.debug,
          writer: lines,
        ),
      );
      const path = 'a\u{E0041}b\u202Ec';
      s.serve(path, pattern(10));
      await s.client.read(path);
      expect(lines.lines.single, contains('"path":"a?b?c"'));
    });
  });

  group('secrecy', () {
    test('no key, plaintext or URL in a log line or an error', () async {
      final lines = Lines();
      final s = Setup(
        logger: createFilteredLogger(
          severity: LogSeverity.debug,
          writer: lines,
        ),
      );
      final secret = Uint8List.fromList(utf8.encode('{"treasure":"x"}'));
      s.serve('m.json', secret);
      await s.client.readJson('m.json');
      await s.client.readRange('m.json', start: 0);
      final errors = <String>[];
      for (final read in <Future<Object?> Function()>[
        () => s.client.read('missing'),
        () => Setup(clientKey: otherKey.text).client.read('m.json'),
      ]) {
        try {
          await read();
        } on Object catch (e) {
          errors.add(e.toString());
        }
      }
      // Positive control: the lines exist and name the path.
      expect(lines.lines, contains(contains('"path":"m.json"')));
      final all = [...lines.lines, ...errors].join('\n');
      for (final forbidden in <String>[
        key.text,
        key.text.substring(5),
        otherKey.text.substring(5),
        'treasure',
        'dev-d.yyt.life',
        'https://',
      ]) {
        expect(all, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}

final class _ThrowingSink implements AssetSink {
  _ThrowingSink(this.error);
  final Object error;
  @override
  void write(Uint8List chunk) => throw error;
  @override
  void reset() {}
}

/// Answers every request with a 200 whose body errors after a few bytes.
final class _FailingBodyClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final controller = StreamController<List<int>>();
    controller
      ..add(<int>[1, 2, 3])
      ..addError(const SocketLikeError());
    unawaited(controller.close());
    return http.StreamedResponse(controller.stream, 200);
  }
}

final class SocketLikeError implements Exception {
  const SocketLikeError();
  @override
  String toString() => 'connection reset by https://dev-d.yyt.life/secret';
}

/// Passes through to [inner] and rewrites response headers.
final class _RewritingClient extends http.BaseClient {
  _RewritingClient(this.inner, this.rewrite);
  final http.Client inner;
  final void Function(Map<String, String>) rewrite;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    final headers = Map<String, String>.of(response.headers);
    rewrite(headers);
    return http.StreamedResponse(
      response.stream,
      response.statusCode,
      headers: headers,
    );
  }
}

/// Passes through to [inner] and cuts every body to [keep] bytes.
final class _TruncatingClient extends http.BaseClient {
  _TruncatingClient(this.inner, this.keep);
  final http.Client inner;
  final int keep;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    var seen = 0;
    final cut = response.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          if (seen >= keep) return;
          final take = keep - seen < chunk.length ? keep - seen : chunk.length;
          sink.add(chunk.sublist(0, take));
          seen += take;
        },
      ),
    );
    return http.StreamedResponse(
      cut,
      response.statusCode,
      headers: response.headers,
    );
  }
}

/// Closes its client on the first write.
final class _ClosingSink implements AssetSink {
  _ClosingSink(this.client);
  final AssetBundleClient client;
  int writes = 0;
  @override
  void write(Uint8List chunk) {
    writes++;
    client.close();
  }

  @override
  void reset() {}
}

final class _CountingSink implements AssetSink {
  int bytes = 0;
  @override
  void write(Uint8List chunk) => bytes += chunk.length;
  @override
  void reset() => bytes = 0;
}

/// Wraps [inner]; `close()` errors every body still streaming, as IOClient's
/// forced close does.
final class _Owned extends http.BaseClient {
  _Owned(this.inner);
  final http.Client inner;
  final List<StreamController<List<int>>> _live = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    final controller = StreamController<List<int>>();
    _live.add(controller);
    final sub = response.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = sub.cancel;
    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() {
    for (final c in _live) {
      if (!c.isClosed) {
        c.addError(const SocketLikeError());
        unawaited(c.close());
      }
    }
  }
}

/// A 200 that sends one chunk, then nothing.
final class _StallingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Left open on purpose: the body stalls.
    // ignore: close_sinks
    final controller = StreamController<List<int>>();
    controller.add(<int>[1, 2, 3]);
    return http.StreamedResponse(controller.stream, 200);
  }
}

/// Never answers.
final class _SilentClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// A 200 with no length whose body never ends.
final class _EndlessClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final chunk = Uint8List(1 << 20);
    Stream<List<int>> endless() async* {
      while (true) {
        yield chunk;
      }
    }

    return http.StreamedResponse(endless(), 200);
  }
}
