/// The codes of an [AssetClientException], in the vocabulary the tslib,
/// csharplib and flutterlib asset clients share. String constants, not an
/// enum: [AssetClientException.code] compares against them.
abstract final class AssetClientErrorCode {
  /// The key is not `yak1.` + 43 base64url characters of 32 bytes, or 32 raw
  /// bytes. Thrown when the client is created.
  static const String badKey = 'bad_key';

  /// The CDN answered `403` or `404`. **A missing object answers `403` on the
  /// yyt CDN**, so the two are one case.
  static const String notFound = 'not_found';

  /// A length no ciphertext has, a failed segment tag, a wrong key, path or
  /// version, or `readJson` on bytes that are not UTF-8 JSON. Not retried: a
  /// wrong key and a wrong path fail the same way every time. (A mutable file
  /// replaced mid-read on a host that sends no ETag also lands here.)
  static const String assetCorrupt = 'asset_corrupt';

  /// Any other status, a host that ignores `Range`, a `206` that is not the
  /// range asked for, an object that kept changing during a read, or a plain
  /// body larger than any asset (a keyed one is `asset_corrupt`).
  static const String http = 'http';

  /// The request never got an answer (in time), or a body failed, stalled,
  /// ended early or ran past its stated length.
  static const String network = 'network';
}

/// The one exception the client throws for a bad key, a refused or failed
/// request, or bytes that do not verify. Local misuse — a malformed
/// `baseUrl` or path, a negative offset, an empty resume ETag — is an
/// [ArgumentError] before any request; the one after requests is a keyed
/// resume offset past the end of the file. A read of a closed client is a
/// [StateError], and whatever a caller's sink throws passes through
/// unchanged.
///
/// Carries a status, a code and at most a fixed phrase: never a key, a URL, a
/// path or a byte of plaintext, so it can be logged as is.
final class AssetClientException implements Exception {
  /// Creates an exception.
  const AssetClientException(this.code, {this.status = 0, this.detail});

  /// One of [AssetClientErrorCode].
  final String code;

  /// HTTP status; `0` when there was no answer to report.
  final int status;

  /// A fixed SDK phrase that narrows [code], or `null`.
  final String? detail;

  @override
  String toString() =>
      'AssetClientException($code, status $status'
      '${detail == null ? '' : ': $detail'})';
}
