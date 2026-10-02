import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/digests/sha256.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_asset_client/yingyeothon_asset_client_io.dart';

import 'support/encrypt.dart';
import 'support/fake_cdn.dart';

const String base = 'https://dev-d.yyt.life/assets/ab_io/';
final key = testKey(5);

String sha256Hex(Uint8List bytes) {
  final out = SHA256Digest().process(bytes);
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Matcher failsWith(String code) =>
    throwsA(isA<AssetClientException>().having((e) => e.code, 'code', code));

/// One bundle over one [FakeCdn], keyed or plain, serving [plain] at `f`.
final class Setup {
  Setup(this.plain, {bool keyed = true, FakeCdn? cdn, http.Client? client})
    : cdn = cdn ?? FakeCdn() {
    etag = this.cdn.serve(
      '${base}f',
      keyed ? encryptAsset(key.bytes, 'f', plain) : plain,
    );
    bundle = AssetBundleClient(
      AssetBundleClientOptions(
        baseUrl: base,
        key: keyed ? key.text : null,
        client: client ?? this.cdn,
      ),
    );
  }

  final Uint8List plain;
  final FakeCdn cdn;
  late final String etag;
  late final AssetBundleClient bundle;

  String get digest => sha256Hex(plain);
}

/// Passes through to [inner]; the next body stops after [cut] bytes and
/// then neither ends nor fails, as a connection that went quiet.
final class _Stalling extends http.BaseClient {
  _Stalling(this.inner);
  final http.Client inner;
  int? cut;
  bool aborted = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.then((_) => aborted = true));
    }
    final response = await inner.send(request);
    final limit = cut;
    if (limit == null) return response;
    cut = null;
    var seen = 0;
    // Left open on purpose: the body stalls.
    // ignore: close_sinks
    final controller = StreamController<List<int>>();
    late final StreamSubscription<List<int>> sub;
    sub = response.stream.listen((chunk) {
      if (seen + chunk.length > limit) {
        controller.add(chunk.sublist(0, limit - seen));
        seen = limit;
        unawaited(sub.cancel());
        return;
      }
      seen += chunk.length;
      controller.add(chunk);
    });
    controller.onCancel = sub.cancel;
    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      headers: response.headers,
    );
  }
}

/// Which file operations fail inside [withFaults].
final class Faults {
  /// A write fails once the part would pass this many bytes.
  int? failWriteAfter;

  /// The part's final, asynchronous flush fails.
  bool failFlush = false;

  /// The part's synchronous flush, before an ETag is written, fails.
  bool failFlushSync = false;

  /// The rename of the part fails.
  bool failRename = false;

  /// Deleting the ETag sidecar fails.
  bool failEtagDelete = false;

  /// The exception the fault threw, to check it reaches the caller as is.
  FileSystemException? thrown;

  FileSystemException fail(String path) => thrown = FileSystemException(
    'No space left on device',
    path,
    const OSError('No space left on device', 28),
  );
}

Future<T> withFaults<T>(Faults faults, Future<T> Function() body) =>
    IOOverrides.runZoned(
      body,
      createFile: (path) =>
          _FaultyFile(Zone.root.run(() => File(path)), faults),
    );

/// A real file whose operations fail on demand. Only what the library and
/// these tests call is implemented.
final class _FaultyFile implements File {
  _FaultyFile(this._real, this._faults);
  final File _real;
  final Faults _faults;

  bool get _isPart => path.endsWith('.part');
  bool get _isEtag => path.endsWith('.part.etag');

  @override
  String get path => _real.path;

  @override
  Directory get parent => _real.parent;

  @override
  bool existsSync() => _real.existsSync();

  @override
  int lengthSync() => _real.lengthSync();

  @override
  Uint8List readAsBytesSync() => _real.readAsBytesSync();

  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      _real.readAsStringSync(encoding: encoding);

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => _real.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => _real.writeAsBytesSync(bytes, mode: mode, flush: flush);

  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      _real.openRead(start, end);

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final file = await _real.open(mode: mode);
    return _isPart ? _FaultyRaf(file, _faults, path) : file;
  }

  @override
  Future<File> rename(String newPath) async {
    if (_isPart && _faults.failRename) throw _faults.fail(path);
    return _real.rename(newPath);
  }

  @override
  void deleteSync({bool recursive = false}) {
    if (_isEtag && _faults.failEtagDelete) throw _faults.fail(path);
    _real.deleteSync(recursive: recursive);
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FaultyRaf implements RandomAccessFile {
  _FaultyRaf(this._real, this._faults, this._path);
  final RandomAccessFile _real;
  final Faults _faults;
  final String _path;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    final limit = _faults.failWriteAfter;
    final length = (end ?? buffer.length) - start;
    if (limit != null && _real.lengthSync() + length > limit) {
      throw _faults.fail(_path);
    }
    await _real.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    if (_faults.failFlush) throw _faults.fail(_path);
    await _real.flush();
    return this;
  }

  @override
  void flushSync() {
    if (_faults.failFlushSync) throw _faults.fail(_path);
    _real.flushSync();
  }

  @override
  Future<void> close() => _real.close();

  @override
  Future<RandomAccessFile> truncate(int length) async {
    await _real.truncate(length);
    return this;
  }

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await _real.setPosition(position);
    return this;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late String destination;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('asset_verified_');
    destination = '${dir.path}/f.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File part() => File('$destination.part');
  File sidecar() => File('$destination.part.etag');
  bool noSideFiles() => !part().existsSync() && !sidecar().existsSync();

  group('verified downloads', () {
    for (final keyed in <bool>[true, false]) {
      final mode = keyed ? 'keyed' : 'plain';

      test(
        '$mode: size, digest and validation pass before the rename',
        () async {
          final s = Setup(pattern(150000), keyed: keyed);
          final seen = <String>[];
          final result = await downloadToFile(
            s.bundle,
            'f',
            destination,
            expectedSize: s.plain.length,
            expectedSha256: s.digest.toUpperCase(),
            validate: (partPath) async {
              // The part is closed and complete; the destination not there.
              expect(File(destination).existsSync(), isFalse);
              final handle = await File(partPath).open();
              seen.add('${await handle.length()}');
              await handle.close();
              expect(File(partPath).readAsBytesSync(), s.plain);
              return true;
            },
          );
          expect(seen, <String>['150000']);
          expect(result.bytes, 150000);
          expect(result.etag, s.etag);
          expect(File(destination).readAsBytesSync(), s.plain);
          expect(noSideFiles(), isTrue);
        },
      );

      test(
        '$mode: a wrong digest keeps the old file and drops the part',
        () async {
          final s = Setup(pattern(90000), keyed: keyed);
          File(destination).writeAsBytesSync(<int>[1, 2, 3]);
          await expectLater(
            downloadToFile(
              s.bundle,
              'f',
              destination,
              expectedSize: 90000,
              expectedSha256: sha256Hex(pattern(90000, 9)),
            ),
            failsWith(AssetClientErrorCode.digestMismatch),
          );
          expect(File(destination).readAsBytesSync(), <int>[1, 2, 3]);
          expect(noSideFiles(), isTrue);
        },
      );

      test('$mode: a file longer than expected stops before the excess '
          'lands', () async {
        final s = Setup(pattern(90000), keyed: keyed);
        File(destination).writeAsBytesSync(<int>[1, 2, 3]);
        var most = 0;
        await expectLater(
          downloadToFile(
            s.bundle,
            'f',
            destination,
            expectedSize: 70000,
            onProgress: (p) => most = p.written,
          ),
          failsWith(AssetClientErrorCode.sizeMismatch),
        );
        expect(most, lessThanOrEqualTo(70000));
        expect(File(destination).readAsBytesSync(), <int>[1, 2, 3]);
        expect(noSideFiles(), isTrue);
      });

      test('$mode: a file shorter than expected fails at the end', () async {
        final s = Setup(pattern(90000), keyed: keyed);
        await expectLater(
          downloadToFile(s.bundle, 'f', destination, expectedSize: 90001),
          failsWith(AssetClientErrorCode.sizeMismatch),
        );
        expect(File(destination).existsSync(), isFalse);
        expect(noSideFiles(), isTrue);
      });

      test(
        '$mode: a modified resumed prefix is caught by the digest',
        () async {
          final s = Setup(pattern(200000), keyed: keyed);
          final prefix = Uint8List.fromList(
            Uint8List.sublistView(s.plain, 0, 65464),
          )..[100] ^= 0xff;
          part().writeAsBytesSync(prefix);
          sidecar().writeAsStringSync(s.etag);
          File(destination).writeAsBytesSync(<int>[9]);
          await expectLater(
            downloadToFile(
              s.bundle,
              'f',
              destination,
              expectedSize: 200000,
              expectedSha256: s.digest,
            ),
            failsWith(AssetClientErrorCode.digestMismatch),
          );
          // It did resume: the prefix was not fetched again.
          expect(s.cdn.requests.last.range, isNot(startsWith('bytes=0-')));
          expect(File(destination).readAsBytesSync(), <int>[9]);
          expect(noSideFiles(), isTrue);
          // The next call starts over and succeeds.
          await downloadToFile(
            s.bundle,
            'f',
            destination,
            expectedSize: 200000,
            expectedSha256: s.digest,
          );
          expect(File(destination).readAsBytesSync(), s.plain);
        },
      );

      test('$mode: a resume hashes the bytes already in the part', () async {
        final s = Setup(pattern(200000), keyed: keyed);
        part().writeAsBytesSync(Uint8List.sublistView(s.plain, 0, 65464));
        sidecar().writeAsStringSync(s.etag);
        await downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSize: 200000,
          expectedSha256: s.digest,
        );
        expect(File(destination).readAsBytesSync(), s.plain);
        expect(s.cdn.requests.last.range, isNot(startsWith('bytes=0-')));
      });
    }

    test('an object that changed resets the digest with the part', () async {
      final s = Setup(pattern(100000, 3));
      part().writeAsBytesSync(pattern(70000, 4));
      sidecar().writeAsStringSync('"stale"');
      await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 100000,
        expectedSha256: s.digest,
      );
      expect(File(destination).readAsBytesSync(), s.plain);
    });

    test(
      'a plain host that ignores Range starts over, digest and all',
      () async {
        final s = Setup(
          pattern(50000),
          keyed: false,
          cdn: FakeCdn(ignoreRange: true),
        );
        part().writeAsBytesSync(Uint8List.sublistView(s.plain, 0, 20000));
        sidecar().writeAsStringSync(s.etag);
        await downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSize: 50000,
          expectedSha256: s.digest,
        );
        expect(File(destination).readAsBytesSync(), s.plain);
      },
    );

    test('a keyed read from a host that ignores Range stays http', () async {
      final s = Setup(pattern(200000), cdn: FakeCdn(ignoreRange: true));
      part().writeAsBytesSync(Uint8List.sublistView(s.plain, 0, 65464));
      sidecar().writeAsStringSync(s.etag);
      File(destination).writeAsBytesSync(<int>[4]);
      await expectLater(
        downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSize: 200000,
          expectedSha256: s.digest,
        ),
        failsWith(AssetClientErrorCode.http),
      );
      // The 200 to `If-Range` read as a changed object first: the part was
      // emptied, and with it the ETag that no longer vouched for it.
      expect(File(destination).readAsBytesSync(), <int>[4]);
      expect(sidecar().existsSync(), isFalse);
    });

    test('an empty file verifies against the empty digest', () async {
      final s = Setup(Uint8List(0));
      await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 0,
        expectedSha256: s.digest,
      );
      expect(File(destination).lengthSync(), 0);
    });
  });

  group('validation', () {
    test(
      'false is asset_rejected: the part goes, the old file stays',
      () async {
        final s = Setup(pattern(1000));
        File(destination).writeAsBytesSync(<int>[7]);
        await expectLater(
          downloadToFile(
            s.bundle,
            'f',
            destination,
            expectedSha256: s.digest,
            validate: (_) => false,
          ),
          failsWith(AssetClientErrorCode.assetRejected),
        );
        expect(File(destination).readAsBytesSync(), <int>[7]);
        expect(noSideFiles(), isTrue);
      },
    );

    test('a throw reaches the caller unchanged and keeps the part, which the '
        'next call finishes offline', () async {
      final s = Setup(pattern(1000));
      final error = StateError('database is locked');
      await expectLater(
        downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSize: 1000,
          expectedSha256: s.digest,
          validate: (_) => throw error,
        ),
        throwsA(same(error)),
      );
      expect(part().lengthSync(), 1000);
      final before = s.cdn.requests.length;
      await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 1000,
        expectedSha256: s.digest,
        validate: (_) => true,
      );
      expect(s.cdn.requests.length, before);
      expect(File(destination).readAsBytesSync(), s.plain);
    });
  });

  group('the part between the check and the rename', () {
    test(
      'a validator that writes to the part makes it digest_mismatch',
      () async {
        final s = Setup(pattern(3000));
        File(destination).writeAsBytesSync(<int>[6]);
        await expectLater(
          downloadToFile(
            s.bundle,
            'f',
            destination,
            expectedSha256: s.digest,
            validate: (p) {
              File(p).writeAsBytesSync(<int>[0], mode: FileMode.append);
              return true;
            },
          ),
          failsWith(AssetClientErrorCode.digestMismatch),
        );
        expect(File(destination).readAsBytesSync(), <int>[6]);
        expect(noSideFiles(), isTrue);
      },
    );

    test('a part swapped for a link is never renamed into place', () async {
      final s = Setup(pattern(3000));
      final target = File('${dir.path}/elsewhere')..writeAsBytesSync(s.plain);
      await expectLater(
        downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSha256: s.digest,
          validate: (p) {
            File(p).deleteSync();
            Link(p).createSync(target.path);
            return true;
          },
        ),
        failsWith(AssetClientErrorCode.digestMismatch),
      );
      expect(
        FileSystemEntity.typeSync(destination, followLinks: false),
        FileSystemEntityType.notFound,
      );
      expect(target.readAsBytesSync(), s.plain);
      expect(noSideFiles(), isTrue);
    });
  });

  group('validator failures', () {
    test('a FileSystemException from validate keeps the part even with '
        'discardOnLocalFailure', () async {
      final s = Setup(pattern(3000));
      const error = FileSystemException('database is locked');
      await expectLater(
        downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSize: 3000,
          expectedSha256: s.digest,
          discardOnLocalFailure: true,
          validate: (_) => throw error,
        ),
        throwsA(same(error)),
      );
      expect(part().lengthSync(), 3000);
    });
  });

  group('offline completion', () {
    test('a complete part with its ETag finishes without a request', () async {
      final s = Setup(pattern(150000));
      // A call that died after the last byte and before the rename.
      part().writeAsBytesSync(s.plain);
      sidecar().writeAsStringSync(s.etag);
      final progress = <AssetDownloadProgress>[];
      final result = await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 150000,
        expectedSha256: s.digest,
        onProgress: progress.add,
      );
      expect(s.cdn.requests, isEmpty);
      expect(result.bytes, 150000);
      expect(result.etag, s.etag);
      expect(progress, hasLength(1));
      expect(progress.single.written, 150000);
      expect(progress.single.total, 150000);
      expect(progress.single.etag, s.etag);
      expect(File(destination).readAsBytesSync(), s.plain);
      expect(noSideFiles(), isTrue);
    });

    test('without its sidecar no ETag is invented', () async {
      final s = Setup(pattern(5000), keyed: false);
      part().writeAsBytesSync(s.plain);
      AssetDownloadProgress? last;
      final result = await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 5000,
        expectedSha256: s.digest,
        onProgress: (p) => last = p,
      );
      expect(s.cdn.requests, isEmpty);
      expect(result.etag, isNull);
      expect(last?.etag, isNull);
      expect(File(destination).readAsBytesSync(), s.plain);
    });

    test('a sidecar that is not an ETag is not returned as one', () async {
      final s = Setup(pattern(5000), keyed: false);
      part().writeAsBytesSync(s.plain);
      sidecar().writeAsStringSync('"a"\r\nx-evil: 1');
      final result = await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 5000,
        expectedSha256: s.digest,
      );
      expect(s.cdn.requests, isEmpty);
      expect(result.etag, isNull);
    });

    test('nor sent as If-Range: the part starts over', () async {
      final s = Setup(pattern(5000), keyed: false);
      part().writeAsBytesSync(Uint8List.sublistView(s.plain, 0, 2000));
      sidecar().writeAsStringSync('"a"\r\nx-evil: 1');
      await downloadToFile(s.bundle, 'f', destination);
      expect(s.cdn.requests.single.range, isNull);
      expect(File(destination).readAsBytesSync(), s.plain);
    });

    test('a same-size corrupt part is never promoted', () async {
      final s = Setup(pattern(5000));
      part().writeAsBytesSync(pattern(5000, 1));
      sidecar().writeAsStringSync(s.etag);
      var validated = 0;
      await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 5000,
        expectedSha256: s.digest,
        validate: (p) {
          validated++;
          return File(p).readAsBytesSync().length == 5000;
        },
      );
      expect(s.cdn.requests, isNotEmpty);
      expect(s.cdn.requests.first.range, isNot(startsWith('bytes=5000')));
      expect(validated, 1);
      expect(File(destination).readAsBytesSync(), s.plain);
    });

    test('size alone is not proof: a complete part still goes to the '
        'network', () async {
      final s = Setup(pattern(5000), keyed: false);
      part().writeAsBytesSync(s.plain);
      sidecar().writeAsStringSync(s.etag);
      await downloadToFile(s.bundle, 'f', destination, expectedSize: 5000);
      expect(s.cdn.requests, isNotEmpty);
      expect(File(destination).readAsBytesSync(), s.plain);
    });

    test('a part longer than expected is discarded and redone', () async {
      final s = Setup(pattern(5000), keyed: false);
      part().writeAsBytesSync(pattern(6000));
      sidecar().writeAsStringSync(s.etag);
      await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 5000,
        expectedSha256: s.digest,
      );
      expect(File(destination).readAsBytesSync(), s.plain);
      // Discarded before any request: one whole GET, no resume.
      expect(s.cdn.requests.single.range, isNull);
    });
  });

  group('local failures', () {
    test('a failed write keeps the side files by default', () async {
      final s = Setup(pattern(200000));
      final faults = Faults()..failWriteAfter = 100000;
      await withFaults(faults, () async {
        await expectLater(
          downloadToFile(s.bundle, 'f', destination),
          throwsA(isA<FileSystemException>()),
        );
      });
      expect(part().lengthSync(), 65464);
      expect(sidecar().existsSync(), isTrue);
    });

    test('with discardOnLocalFailure a failed write gives the space back, '
        'and the error is the original', () async {
      final s = Setup(pattern(200000));
      final faults = Faults()..failWriteAfter = 100000;
      Object? caught;
      await withFaults(faults, () async {
        try {
          await downloadToFile(
            s.bundle,
            'f',
            destination,
            expectedSha256: s.digest,
            discardOnLocalFailure: true,
          );
        } on Object catch (e) {
          caught = e;
        }
      });
      expect(caught, same(faults.thrown));
      expect(noSideFiles(), isTrue);
    });

    test('with discardOnLocalFailure a failed flush discards too', () async {
      final s = Setup(pattern(200000));
      for (final sync in <bool>[false, true]) {
        final faults = Faults()
          ..failFlush = !sync
          ..failFlushSync = sync;
        Object? caught;
        await withFaults(faults, () async {
          try {
            await downloadToFile(
              s.bundle,
              'f',
              destination,
              discardOnLocalFailure: true,
            );
          } on Object catch (e) {
            caught = e;
          }
        });
        expect(caught, same(faults.thrown), reason: 'sync: $sync');
        expect(noSideFiles(), isTrue, reason: 'sync: $sync');
      }
    });

    test('what onProgress throws is the caller\'s: a FileSystemException '
        'from it keeps the part even with discardOnLocalFailure', () async {
      final s = Setup(pattern(200000));
      const error = FileSystemException('the app\'s own');
      await expectLater(
        downloadToFile(
          s.bundle,
          'f',
          destination,
          discardOnLocalFailure: true,
          expectedSize: 200000,
          onProgress: (_) => throw error,
        ),
        throwsA(same(error)),
      );
      expect(part().lengthSync(), 65464);
      expect(sidecar().existsSync(), isTrue);
    });

    test(
      'a failed rename keeps the verified part for an offline finish',
      () async {
        final s = Setup(pattern(3000));
        File(destination).writeAsBytesSync(<int>[5]);
        final faults = Faults()..failRename = true;
        await withFaults(faults, () async {
          await expectLater(
            downloadToFile(
              s.bundle,
              'f',
              destination,
              expectedSize: 3000,
              expectedSha256: s.digest,
              discardOnLocalFailure: true,
            ),
            throwsA(isA<FileSystemException>()),
          );
        });
        expect(File(destination).readAsBytesSync(), <int>[5]);
        expect(part().lengthSync(), 3000);
        final before = s.cdn.requests.length;
        await downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSize: 3000,
          expectedSha256: s.digest,
        );
        expect(s.cdn.requests.length, before);
        expect(File(destination).readAsBytesSync(), s.plain);
      },
    );

    test('a sidecar that cannot be deleted after the rename is not a '
        'failure', () async {
      final s = Setup(pattern(3000));
      final faults = Faults()..failEtagDelete = true;
      final result = await withFaults(
        faults,
        () => downloadToFile(s.bundle, 'f', destination),
      );
      expect(result.bytes, 3000);
      expect(File(destination).readAsBytesSync(), s.plain);
      expect(sidecar().existsSync(), isTrue);
      // The next call discards the lone sidecar and downloads afresh.
      File(destination).deleteSync();
      await downloadToFile(s.bundle, 'f', destination);
      expect(sidecar().existsSync(), isFalse);
    });
  });

  group('cancellation', () {
    test('a stalled download ends at once as cancelled, the part kept and '
        'resumable through the same client', () async {
      final cdn = FakeCdn();
      final client = _Stalling(cdn);
      final s = Setup(pattern(200000), cdn: cdn, client: client);
      client.cut = 100000;
      final cancel = Completer<void>();
      final download = downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSha256: s.digest,
        cancel: cancel.future,
        onProgress: (p) {
          if (p.written >= 65464) Timer.run(cancel.complete);
        },
      );
      final watch = Stopwatch()..start();
      await expectLater(download, failsWith(AssetClientErrorCode.cancelled));
      // Far inside the 30 s idle timeout.
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(client.aborted, isTrue);
      expect(part().lengthSync(), 65464);
      expect(sidecar().existsSync(), isTrue);
      await downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSha256: s.digest,
      );
      expect(File(destination).readAsBytesSync(), s.plain);
      expect(s.cdn.requests.last.range, isNot(startsWith('bytes=0-')));
    });

    test('an already-completed cancel touches nothing', () async {
      final s = Setup(pattern(1000));
      final deep = '${dir.path}/deep/f.db';
      await expectLater(
        downloadToFile(s.bundle, 'f', deep, cancel: Future.value()),
        failsWith(AssetClientErrorCode.cancelled),
      );
      expect(s.cdn.requests, isEmpty);
      expect(Directory('${dir.path}/deep').existsSync(), isFalse);
    });

    test('a cancel stops the re-reading of a part', () async {
      final s = Setup(pattern(150000));
      part().writeAsBytesSync(s.plain);
      final cancel = Completer<void>();
      final download = downloadToFile(
        s.bundle,
        'f',
        destination,
        expectedSize: 150000,
        expectedSha256: s.digest,
        cancel: cancel.future,
      );
      cancel.complete();
      await expectLater(download, failsWith(AssetClientErrorCode.cancelled));
      // A hash that ignored the signal would have finished offline.
      expect(File(destination).existsSync(), isFalse);
      expect(s.cdn.requests, isEmpty);
      expect(part().lengthSync(), 150000);
    });

    test('a cancel during validation stops before the rename', () async {
      final s = Setup(pattern(3000));
      final cancel = Completer<void>();
      await expectLater(
        downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSize: 3000,
          expectedSha256: s.digest,
          cancel: cancel.future,
          validate: (_) async {
            cancel.complete();
            await Future<void>.delayed(Duration.zero);
            return true;
          },
        ),
        failsWith(AssetClientErrorCode.cancelled),
      );
      expect(File(destination).existsSync(), isFalse);
      expect(part().lengthSync(), 3000);
    });

    test('a cancel that fails after a refused argument is not an uncaught '
        'error', () async {
      final s = Setup(pattern(10));
      final cancel = Completer<void>();
      await expectLater(
        downloadToFile(s.bundle, '../f', destination, cancel: cancel.future),
        throwsA(isA<ArgumentError>()),
      );
      cancel.completeError(StateError('screen closed'));
      await pumpEventQueue();
    });
  });

  group('arguments and secrecy', () {
    test('a bad size or digest is refused before anything on disk', () async {
      final s = Setup(pattern(10));
      final deep = '${dir.path}/deep/x';
      for (final call in <Future<void> Function()>[
        () => downloadToFile(s.bundle, 'f', deep, expectedSize: -1),
        () => downloadToFile(s.bundle, 'f', deep, expectedSha256: 'abc'),
        () => downloadToFile(s.bundle, 'f', deep, expectedSha256: 'g' * 64),
      ]) {
        await expectLater(call(), throwsA(isA<ArgumentError>()));
      }
      expect(Directory('${dir.path}/deep').existsSync(), isFalse);
      expect(s.cdn.requests, isEmpty);
    });

    test('the new failures say a code and nothing of the input', () async {
      final s = Setup(pattern(10));
      final texts = <String>[];
      for (final call in <Future<void> Function()>[
        () => downloadToFile(
          s.bundle,
          'f',
          destination,
          expectedSha256: sha256Hex(pattern(10, 2)),
        ),
        () => downloadToFile(s.bundle, 'f', destination, expectedSize: 3),
        () =>
            downloadToFile(s.bundle, 'f', destination, validate: (_) => false),
        () =>
            downloadToFile(s.bundle, 'f', destination, cancel: Future.value()),
      ]) {
        try {
          await call();
          fail('no failure');
        } on AssetClientException catch (e) {
          texts.add(e.toString());
        }
      }
      expect(texts, <String>[
        'AssetClientException(digest_mismatch, status 0)',
        'AssetClientException(size_mismatch, status 0)',
        'AssetClientException(asset_rejected, status 0)',
        'AssetClientException(cancelled, status 0)',
      ]);
    });
  });
}
