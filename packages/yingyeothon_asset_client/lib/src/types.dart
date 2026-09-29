import 'dart:async';
import 'dart:typed_data';

/// Where `download` puts the plaintext, one verified piece at a time.
abstract interface class AssetSink {
  /// The next plaintext bytes, in order. Awaited before the next piece. The
  /// list may be a view the client reuses: copy it to keep it.
  FutureOr<void> write(Uint8List chunk);

  /// The object changed since the bytes already written (or since the
  /// resume): drop everything, the download starts again from byte 0.
  FutureOr<void> reset();
}

/// Where an earlier download stopped.
final class AssetResume {
  /// Creates a resume point. [offset] is a non-negative byte count and
  /// [etag] a non-empty ETag, as an earlier [AssetDownloadProgress] reported.
  const AssetResume({required this.offset, required this.etag});

  /// Plaintext bytes the sink already holds from an earlier download.
  final int offset;

  /// The ETag that earlier download reported; another one starts over.
  final String etag;
}

/// Reported after every piece a download writes, and once for a download
/// that wrote nothing.
final class AssetDownloadProgress {
  /// Creates a report.
  const AssetDownloadProgress({required this.written, this.total, this.etag});

  /// Plaintext bytes the sink holds, a resumed offset included.
  final int written;

  /// The file's plaintext length; `null` only for a plain file whose length
  /// the client cannot trust: a compressed or unsized body, and in CORS-safe
  /// mode any whole-file answer.
  final int? total;

  /// The object's ETag; keep it with [written] to resume later.
  final String? etag;
}

/// What a finished download wrote.
final class AssetDownloadResult {
  /// Creates a result.
  const AssetDownloadResult({required this.bytes, this.etag});

  /// The file's plaintext length, now all in the sink.
  final int bytes;

  /// The object's ETag, when the host named one.
  final String? etag;
}
