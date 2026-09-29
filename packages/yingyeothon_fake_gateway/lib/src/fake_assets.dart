import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import 'asset_encryption.dart';

/// One asset bundle the fake CDN serves under `/assets/{id}/`. With a [key]
/// every file is `yyt-enc v1` ciphertext of the plaintext given, its path as
/// the associated data — what `yyt asset sync` uploads for an encrypted
/// bundle; without one the bytes are served as given.
final class FakeAssetBundle {
  /// Encrypts [files] under [key] when one is given.
  factory FakeAssetBundle({
    required String id,
    required Map<String, List<int>> files,
    Uint8List? key,
  }) => FakeAssetBundle._(
    id,
    Map<String, Uint8List>.unmodifiable(<String, Uint8List>{
      for (final e in files.entries)
        e.key: key == null
            ? Uint8List.fromList(e.value)
            : encryptAsset(key, e.key, Uint8List.fromList(e.value)),
    }),
  );

  FakeAssetBundle._(this.id, this.objects);

  /// The path segment after `/assets/`.
  final String id;

  /// What the CDN serves, by path below the bundle. `FakeGateway.start`
  /// copies them, so a change made after it changes nothing on the wire.
  final Map<String, Uint8List> objects;
}

/// The CDN behind `/assets/*`: `GET` and `HEAD`, one `Range` (`a-b`, `a-`,
/// `-n`), `If-Range` against a strong `ETag`, `416` past the end, and `403`
/// for an object that is not there, as CloudFront in front of a private
/// bucket answers.
final class FakeAssetStore {
  /// Serves [bundles].
  FakeAssetStore(Iterable<FakeAssetBundle> bundles)
    : _objects = <String, _Object>{
        for (final b in bundles)
          for (final e in b.objects.entries)
            '${b.id}/${e.key}': _Object(Uint8List.fromList(e.value)),
      };

  final Map<String, _Object> _objects;

  /// Whether [path] is one this store serves.
  static bool handles(String path) => path.startsWith('/assets/');

  /// Answers one request.
  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    try {
      final method = request.method;
      if (method != 'GET' && method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      // Parsed before anything is answered: a repeated header or a bad
      // escape is a 400, as at the edge, not a half-written 200.
      final String key;
      final String? ifRange;
      final _Range? range;
      try {
        key = request.uri.pathSegments.skip(1).join('/');
        ifRange = request.headers.value('if-range');
        range = _Range.parse(request.headers.value('range'));
      } on Object {
        response.statusCode = HttpStatus.badRequest;
        return;
      }
      final object = _objects[key];
      if (object == null) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final bytes = object.bytes;
      response.headers
        ..set('accept-ranges', 'bytes')
        ..set('etag', object.etag)
        ..contentType = ContentType.binary;
      var start = 0;
      var end = bytes.length;
      if (range != null && (ifRange == null || ifRange == object.etag)) {
        final at = range.resolve(bytes.length);
        if (at == null) {
          response
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..headers.set('content-range', 'bytes */${bytes.length}');
          return;
        }
        (start, end) = at;
        response
          ..statusCode = HttpStatus.partialContent
          ..headers.set(
            'content-range',
            'bytes $start-${end - 1}/${bytes.length}',
          );
      }
      response.contentLength = end - start;
      if (method == 'GET') {
        response.add(Uint8List.sublistView(bytes, start, end));
      }
    } finally {
      await response.close();
    }
  }
}

final class _Object {
  _Object(this.bytes) : etag = '"${c.md5.convert(bytes)}"';
  final Uint8List bytes;
  final String etag;
}

/// One `bytes=` range; anything else (several ranges, another unit) is
/// ignored and the whole object served, as a host may.
final class _Range {
  const _Range(this.first, this.last, this.suffix);

  final int? first;
  final int? last;
  final int? suffix;

  static final RegExp _pattern = RegExp(r'^bytes=(\d*)-(\d*)$');

  static _Range? parse(String? raw) {
    if (raw == null) return null;
    final m = _pattern.firstMatch(raw.trim());
    if (m == null) return null;
    final a = int.tryParse(m.group(1)!);
    final b = int.tryParse(m.group(2)!);
    if (a == null && b == null) return null;
    if (a == null) return _Range(null, null, b);
    if (b != null && b < a) return null;
    return _Range(a, b, null);
  }

  /// `[start, end)` within [length], or `null` when unsatisfiable.
  (int, int)? resolve(int length) {
    final n = suffix;
    if (n != null) {
      if (n == 0 || length == 0) return null;
      return (n >= length ? 0 : length - n, length);
    }
    final a = first!;
    if (a >= length) return null;
    final b = last;
    return (a, b == null || b >= length ? length : b + 1);
  }
}
