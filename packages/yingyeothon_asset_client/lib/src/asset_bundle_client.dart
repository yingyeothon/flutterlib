import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'internal/client_impl.dart';
import 'types.dart';

/// Whether this program was compiled for a browser, where every request to
/// the CDN is cross-origin.
const bool _onWeb = bool.fromEnvironment('dart.library.js_interop');

/// How to reach one bundle. Immutable; the client copies the key.
final class AssetBundleClientOptions {
  /// Creates options.
  const AssetBundleClientOptions({
    required this.baseUrl,
    this.key,
    this.corsSafe,
    this.client,
    this.logger,
    this.responseTimeout = const Duration(seconds: 30),
    this.bodyIdleTimeout = const Duration(seconds: 30),
  });

  /// `https://{cdn}/assets/{bundleId}/` for a live bundle, plus `{version}/`
  /// for one version of a versioned bundle. The CDN is `d.yyt.life` on prod
  /// and `dev-d.yyt.life` on dev; there is no default.
  final String baseUrl;

  /// The key of an encrypted bundle: the `yak1.` text `yyt asset key show`
  /// prints, or its 32 raw bytes as a `Uint8List`. Omit it for a plain
  /// bundle. Copied at construction, zeroed by `close()`, never logged.
  final Object? key;

  /// Send only CORS-safelisted request headers (`Range`, never `If-Range` or
  /// `Cache-Control`) and read only the response headers the yyt CDN exposes
  /// to scripts (`ETag`, `Content-Length`); a ranged read then costs a `HEAD`
  /// first. Defaults to `true` on web and `false` elsewhere.
  final bool? corsSafe;

  /// The HTTP client; defaults to a fresh [http.Client], which `close()`
  /// releases. One passed here stays the caller's to close.
  final http.Client? client;

  /// Receives one `debug` line per request, and a `warn` or `info` line when
  /// a request fails, a browser refuses `Range` or a read starts over;
  /// defaults to [nullLogger].
  final Logger? logger;

  /// How long a request may wait for its response headers before it is
  /// aborted as `network`.
  final Duration responseTimeout;

  /// How long a body may go without delivering its next piece before the
  /// read ends as `network` — a connection that went quiet mid-body, as when
  /// a phone changes networks. A body is otherwise read at the caller's pace.
  final Duration bodyIdleTimeout;

  /// [corsSafe], or the platform's default.
  bool get effectiveCorsSafe => corsSafe ?? _onWeb;
}

/// A reader for one asset bundle on the yyt CDN. With a key it decrypts
/// `yyt-enc v1` ciphertext, verifying every 64 KiB segment before releasing a
/// byte of it; without one it reads a plain bundle through the same calls.
///
/// A `path` is the file's object key below the bundle: segments separated by
/// `/`, no leading slash, no empty, `.` or `..` segment, no backslash, no
/// control character, no lone UTF-16 surrogate. A malformed one is an
/// [ArgumentError] before any
/// request; every failure the CDN, the network or the bytes cause is an
/// `AssetClientException`.
abstract interface class AssetBundleClient {
  /// Creates a client. Throws `AssetClientException` (`bad_key`) for a key
  /// that is not canonical, and [ArgumentError] for a `baseUrl` that is not
  /// an http(s) URL — or, with a key, not of the bundle or version shape.
  factory AssetBundleClient(AssetBundleClientOptions options) =
      AssetBundleClientImpl;

  /// The whole file, verified before any byte is returned. [noCache] sends
  /// `Cache-Control: no-cache` (never in CORS-safe mode, where it would need a
  /// preflight the CDN refuses).
  Future<Uint8List> read(String path, {bool noCache = false});

  /// The whole file as UTF-8 JSON, decoded (a leading byte-order mark is
  /// dropped); anything else, or a document over the codec's limits, is
  /// `asset_corrupt`.
  Future<Object?> readJson(String path, {bool noCache = false});

  /// Plaintext bytes `[start, end)`, clamped to the file. An encrypted file
  /// fetches only the segments the window covers. [end] omitted reads to
  /// the end; `end <= start` returns empty without a request.
  Future<Uint8List> readRange(
    String path, {
    required int start,
    int? end,
    bool noCache = false,
  });

  /// Streams the file into [sink], each encrypted segment verified before a
  /// byte of it is written, and continues from [resume] while the object
  /// still has that ETag (otherwise `sink.reset()` and from byte 0).
  /// [onProgress] fires after every piece. Whatever the sink or [onProgress]
  /// throws ends the download and reaches the caller unchanged. A keyed
  /// resume offset past the end of the file is an [ArgumentError], raised
  /// only once the last segment verified; a plain one starts over.
  Future<AssetDownloadResult> download(
    String path, {
    required AssetSink sink,
    AssetResume? resume,
    void Function(AssetDownloadProgress progress)? onProgress,
    bool noCache = false,
  });

  /// Zeroes the key and every derived key, and releases the default HTTP
  /// client. A read in flight stops at its next piece with a [StateError],
  /// keyed or plain; every later call throws [StateError]. Idempotent.
  void close();
}
