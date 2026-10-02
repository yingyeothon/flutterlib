/// A resumable download of one asset straight to a file. Needs `dart:io`,
/// so it is a library of its own: the core `yingyeothon_asset_client.dart`
/// stays importable on web. It re-exports the core, so one import serves.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

import 'src/internal/client_impl.dart' show resumePastEnd;
import 'src/internal/http.dart' show CancelSignal, cancelledError;
import 'src/internal/paths.dart' show checkPath;
import 'yingyeothon_asset_client.dart';

export 'yingyeothon_asset_client.dart';

final RegExp _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');

/// The longest sidecar read back; an ETag is far shorter.
const int _maxEtag = 256;
final RegExp _etagText = RegExp(r'^[\x21-\x7e]{1,256}$');

/// Downloads [path] of [bundle] into the file at [destination], resuming an
/// earlier download of the same object that this function left unfinished.
///
/// The plaintext goes to `<destination>.part` and the object's ETag to
/// `<destination>.part.etag`; with a keyed bundle the part only ever holds
/// verified bytes. A call that finds both resumes from the part's length
/// while the object still has that ETag, and starts over otherwise.
/// `<destination>` — whose folder is created if missing — appears only after
/// every check below passed and the part, flushed and closed, was renamed
/// over any file already there; until then a file already there is left as
/// it was. The two side files are then gone; a sidecar that cannot be
/// deleted after the rename is left for the next call, which discards it,
/// and the call still succeeds.
///
/// **What the app trusts** — its manifest — goes in the optional checks:
///
/// - [expectedSize]: the plaintext length. A byte past it ends the download
///   before it is written, and a short file fails at the end; both are
///   `size_mismatch`. A part already longer is discarded before anything
///   is fetched.
/// - [expectedSha256]: the plaintext's SHA-256 as 64 hex digits, either
///   case. The bytes a resume found in the part count, re-read from disk
///   (with no progress report while that runs); a mismatch is
///   `digest_mismatch`. For a keyed bundle this is the digest of the
///   plaintext, not of what the CDN serves.
/// - [validate]: the app's own check of the finished part, given the
///   part's path after the byte checks passed and the part was closed, and
///   before the rename. **Return `false` for a file that is not usable** —
///   catch your format's own error to do so — which is `asset_rejected` and
///   deletes the part; throw only for a failure that says nothing about the
///   file, which keeps the part and reaches the caller unchanged, so the
///   next call checks the same part again. Open the part read-only and
///   close it before returning: a part whose size or modification time
///   changed meanwhile, or that is no longer a plain file, is
///   `digest_mismatch` and deleted, and files the check creates beside it
///   (a SQLite `-journal`, `-wal`, `-shm`) are the app's to delete.
///
/// With both [expectedSize] and [expectedSha256], a part that already has
/// that size — a call that died between the last byte and the rename — is
/// finished **without a request**: hashed, reported once as complete (with
/// the sidecar's ETag, `null` when there is none or it is not a plausible
/// ETag), validated and renamed. A same-size part whose digest differs is
/// discarded and the file downloaded afresh. Size alone is not proof:
/// without the digest such a part resumes as usual.
///
/// What a failure does with the side files:
///
/// | Failure | Side files |
/// | --- | --- |
/// | `size_mismatch`, `digest_mismatch`, `asset_rejected` | deleted |
/// | a [FileSystemException] reading or writing the part or its ETag | deleted with [discardOnLocalFailure], kept otherwise |
/// | anything else — `network`, `http`, `not_found`, `asset_corrupt`, `cancelled`, a closed client, a throw from [onProgress] or [validate], a failed rename | kept, to resume or to finish offline |
///
/// A side file that cannot be deleted is left; the failure the caller sees
/// is still the one that ended the download. [discardOnLocalFailure] gives
/// back the space a full disk would otherwise keep held.
///
/// [cancel] is that of [AssetBundleClient.download]. It is also checked
/// while a part is re-read from disk, and before and after [validate]; once
/// the rename has begun the call completes.
///
/// **The file is plaintext on disk**, decrypted: put it in the app's private
/// storage. **One call per destination at a time**: two would write the same
/// part. To give up on a download, delete the two side files. Skipping a
/// destination that is already there and closing the app's own handles on
/// it before a call are the app's to do.
///
/// Errors are those of [AssetBundleClient.download], the three codes above
/// and the [FileSystemException]s of the part, its ETag and the rename. A
/// negative [expectedSize] or an [expectedSha256] that is not 64 hex digits
/// is an [ArgumentError] before anything on disk is touched.
Future<AssetDownloadResult> downloadToFile(
  AssetBundleClient bundle,
  String path,
  String destination, {
  void Function(AssetDownloadProgress progress)? onProgress,
  bool noCache = false,
  int? expectedSize,
  String? expectedSha256,
  FutureOr<bool> Function(String partPath)? validate,
  bool discardOnLocalFailure = false,
  Future<void>? cancel,
}) async {
  // Watched first: a cancel completed with an error after a refused
  // argument must not surface as an uncaught error.
  final signal = cancel == null ? null : CancelSignal(cancel);
  // Refused before anything on disk is touched: a manifest-chosen name may
  // be both the asset path and part of the destination.
  checkPath(path);
  if (expectedSize != null && expectedSize < 0) {
    throw ArgumentError('expectedSize must not be negative');
  }
  if (expectedSha256 != null && !_sha256Hex.hasMatch(expectedSha256)) {
    throw ArgumentError('expectedSha256 must be 64 hex digits');
  }
  if (signal != null) {
    // One turn of the microtask queue, as `download` does: a cancel that
    // had already completed touches nothing.
    await Future<void>.value();
    if (signal.isSet) throw cancelledError;
  }
  try {
    return await _download(
      bundle,
      path,
      destination,
      onProgress: onProgress,
      noCache: noCache,
      expectedSize: expectedSize,
      digest: expectedSha256?.toLowerCase(),
      validate: validate,
      discardOnLocalFailure: discardOnLocalFailure,
      cancel: cancel,
      signal: signal,
    );
  } on _CallerError catch (e) {
    // What `onProgress` threw, unchanged and never taken for a failure of
    // this function's own.
    Error.throwWithStackTrace(e.error, e.stack);
  }
}

/// What the caller's `onProgress` threw, carried past this function's own
/// failure handling.
final class _CallerError {
  const _CallerError(this.error, this.stack);
  final Object error;
  final StackTrace stack;
}

Future<AssetDownloadResult> _download(
  AssetBundleClient bundle,
  String path,
  String destination, {
  required void Function(AssetDownloadProgress progress)? onProgress,
  required bool noCache,
  required int? expectedSize,
  required String? digest,
  required FutureOr<bool> Function(String partPath)? validate,
  required bool discardOnLocalFailure,
  required Future<void>? cancel,
  required CancelSignal? signal,
}) async {
  final part = File('$destination.part');
  final etagFile = File('$destination.part.etag');
  final sides = _SideFiles(part, etagFile);
  await part.parent.create(recursive: true);
  // A side file that is a link would write the plaintext into its target.
  for (final side in <File>[part, etagFile]) {
    if (FileSystemEntity.typeSync(side.path, followLinks: false) ==
        FileSystemEntityType.link) {
      Link(side.path).deleteSync();
    }
  }

  void report(AssetDownloadProgress progress) {
    if (onProgress == null) return;
    try {
      onProgress(progress);
    } on Object catch (e, stack) {
      throw _CallerError(e, stack);
    }
  }

  var offset = 0;
  String? savedEtag;

  Future<({_FileSink sink, AssetDownloadResult result})> attempt() async {
    final file = await part.open(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    final sink = _FileSink(
      file,
      () {
        // The part is being emptied for another object: its old ETag must
        // not survive beside the new bytes.
        if (etagFile.existsSync()) etagFile.deleteSync();
        savedEtag = null;
      },
      expectedSize,
      hashing: digest != null,
    );
    var done = false;
    try {
      if (offset > 0) await sink.seed(part, offset, signal);
      final result = await bundle.download(
        path,
        sink: sink,
        resume: offset > 0 && savedEtag != null
            ? AssetResume(offset: offset, etag: savedEtag!)
            : null,
        noCache: noCache,
        cancel: cancel,
        onProgress: (progress) {
          // Written after the bytes it vouches for, so a crash in between
          // leaves a part without its ETag, which the next call discards.
          final etag = progress.etag;
          if (etag != null && etag != savedEtag) {
            // The bytes it vouches for reach the disk first.
            file.flushSync();
            etagFile.writeAsStringSync(etag, flush: true);
            savedEtag = etag;
          }
          report(progress);
        },
      );
      await file.flush();
      done = true;
      return (sink: sink, result: result);
    } finally {
      if (done) {
        await file.close();
      } else {
        try {
          await file.close();
        } on Object {
          // The failure that ended the transfer is the one to report.
        }
      }
    }
  }

  Future<AssetDownloadResult> transfer() async {
    if (expectedSize != null && part.existsSync()) {
      final length = part.lengthSync();
      if (length > expectedSize) {
        sides.discard();
      } else if (length == expectedSize && digest != null) {
        if (await _hashFile(part, length, signal) == digest) {
          final etag = sides.readEtag();
          report(
            AssetDownloadProgress(written: length, total: length, etag: etag),
          );
          return AssetDownloadResult(bytes: length, etag: etag);
        }
        sides.discard();
      }
    }

    if (part.existsSync() && etagFile.existsSync()) {
      final etag = sides.readEtag();
      if (etag != null) {
        savedEtag = etag;
        offset = part.lengthSync();
      }
    }
    if (offset == 0 && etagFile.existsSync()) etagFile.deleteSync();

    ({_FileSink sink, AssetDownloadResult result}) received;
    try {
      received = await attempt();
    } on ArgumentError catch (e) {
      // A part longer than the file it resumes: nothing to keep. Once more
      // from byte 0. What `onProgress` throws never lands here.
      if (offset == 0 || e.message != resumePastEnd) rethrow;
      offset = 0;
      savedEtag = null;
      if (etagFile.existsSync()) etagFile.deleteSync();
      received = await attempt();
    }
    if (expectedSize != null && received.sink.written != expectedSize) {
      sides.discard();
      throw const AssetClientException(AssetClientErrorCode.sizeMismatch);
    }
    if (digest != null && received.sink.digestHex() != digest) {
      sides.discard();
      throw const AssetClientException(AssetClientErrorCode.digestMismatch);
    }
    return received.result;
  }

  final AssetDownloadResult result;
  try {
    result = await transfer();
  } on AssetClientException catch (e) {
    if (e.code == AssetClientErrorCode.sizeMismatch) sides.discard();
    rethrow;
  } on FileSystemException {
    if (discardOnLocalFailure) sides.discard();
    rethrow;
  }
  await _promote(sides, destination, validate, signal);
  return result;
}

/// `<destination>.part` and `<destination>.part.etag`.
final class _SideFiles {
  const _SideFiles(this.part, this.etag);

  final File part;
  final File etag;

  /// The ETag the sidecar holds, or `null` for none, an unreadable one or
  /// one that is not the short printable text an ETag is: the file is on
  /// disk, and its text reaches `If-Range` and the caller's result.
  String? readEtag() {
    try {
      if (etag.lengthSync() > _maxEtag) return null;
      final text = etag.readAsStringSync();
      return _etagText.hasMatch(text) ? text : null;
    } on FileSystemException {
      // Missing, or not the text this library writes.
      return null;
    }
  }

  /// Deletes both, as far as it can: a failure here must never replace the
  /// one that made the part unusable.
  void discard() {
    for (final side in <File>[part, etag]) {
      try {
        if (side.existsSync()) side.deleteSync();
      } on FileSystemException {
        // Left for the next call or the app's own cleanup.
      }
    }
  }
}

/// Validates the closed, verified part and renames it over [destination],
/// as long as it is still the plain file that was verified.
Future<void> _promote(
  _SideFiles sides,
  String destination,
  FutureOr<bool> Function(String partPath)? validate,
  CancelSignal? signal,
) async {
  final part = sides.part;
  if (signal != null && signal.isSet) throw cancelledError;
  final verified = _plainStat(sides);
  if (validate != null && !await validate(part.path)) {
    sides.discard();
    throw const AssetClientException(AssetClientErrorCode.assetRejected);
  }
  if (signal != null && signal.isSet) throw cancelledError;
  // Whatever wrote to the part since it was hashed — a validator that
  // opened it for writing, a second call for the same destination — made
  // it another file than the one verified.
  final now = _plainStat(sides);
  if (now.size != verified.size || now.modified != verified.modified) {
    sides.discard();
    throw const AssetClientException(
      AssetClientErrorCode.digestMismatch,
      detail: 'the part changed after it was verified',
    );
  }
  // A failed rename leaves the verified part, which the next call finishes
  // without a request when it knows the size and the digest.
  await part.rename(destination);
  try {
    if (sides.etag.existsSync()) sides.etag.deleteSync();
  } on FileSystemException {
    // The file is in place; a lone sidecar is discarded by the next call.
  }
}

/// The part's stat, refused as `digest_mismatch` unless it is a plain file:
/// a link put in its place would be renamed into the destination as is.
FileStat _plainStat(_SideFiles sides) {
  final stat = FileStat.statSync(sides.part.path);
  final type = FileSystemEntity.typeSync(sides.part.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    if (type == FileSystemEntityType.link) Link(sides.part.path).deleteSync();
    sides.discard();
    throw const AssetClientException(
      AssetClientErrorCode.digestMismatch,
      detail: 'the part was replaced after it was verified',
    );
  }
  return stat;
}

/// The SHA-256 of [file]'s first [length] bytes, read piece by piece.
Future<String> _hashFile(File file, int length, CancelSignal? signal) async {
  final hash = SHA256Digest();
  await _feed(hash, file, length, signal);
  return _finish(hash);
}

Future<void> _feed(
  SHA256Digest hash,
  File file,
  int length,
  CancelSignal? signal,
) async {
  await for (final piece in file.openRead(0, length)) {
    if (signal != null && signal.isSet) throw cancelledError;
    final bytes = piece is Uint8List ? piece : Uint8List.fromList(piece);
    hash.update(bytes, 0, bytes.length);
  }
}

String _finish(SHA256Digest hash) {
  final out = Uint8List(hash.digestSize);
  hash.doFinal(out, 0);
  final text = StringBuffer();
  for (final byte in out) {
    text.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return text.toString();
}

final class _FileSink implements AssetSink {
  _FileSink(this._file, this._onReset, this._limit, {required bool hashing})
    : _hash = hashing ? SHA256Digest() : null;

  final RandomAccessFile _file;
  final void Function() _onReset;
  final int? _limit;
  SHA256Digest? _hash;

  /// Plaintext bytes in the part.
  int written = 0;

  /// Counts, and hashes when asked to, the [length] bytes a resume keeps.
  Future<void> seed(File part, int length, CancelSignal? signal) async {
    final hash = _hash;
    if (hash != null) await _feed(hash, part, length, signal);
    written = length;
  }

  /// The digest of everything written, as lowercase hex; once only.
  String digestHex() => _finish(_hash!);

  @override
  Future<void> write(Uint8List chunk) async {
    final limit = _limit;
    if (limit != null && written + chunk.length > limit) {
      throw const AssetClientException(AssetClientErrorCode.sizeMismatch);
    }
    await _file.writeFrom(chunk);
    _hash?.update(chunk, 0, chunk.length);
    written += chunk.length;
  }

  @override
  Future<void> reset() async {
    _onReset();
    await _file.truncate(0);
    await _file.setPosition(0);
    if (_hash != null) _hash = SHA256Digest();
    written = 0;
  }
}
