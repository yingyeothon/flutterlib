/// A resumable download of one asset straight to a file. Needs `dart:io`,
/// so it is a library of its own: the core `yingyeothon_asset_client.dart`
/// stays importable on web. It re-exports the core, so one import serves.
library;

import 'dart:io';
import 'dart:typed_data';

import 'src/internal/client_impl.dart' show resumePastEnd;
import 'src/internal/paths.dart' show checkPath;
import 'yingyeothon_asset_client.dart';

export 'yingyeothon_asset_client.dart';

/// Downloads [path] of [bundle] into the file at [destination], resuming an
/// earlier download of the same object that this function left unfinished.
///
/// The plaintext goes to `<destination>.part` and the object's ETag to
/// `<destination>.part.etag`; with a keyed bundle the part only ever holds
/// verified bytes. A call that finds both resumes from the part's length
/// while the object still has that ETag, and starts over otherwise.
/// `<destination>` — whose folder is created if missing — appears only after
/// the last segment verified, flushed to disk and renamed over any file
/// already there; the two side files are then gone.
///
/// **The file is plaintext on disk**, decrypted: put it in the app's private
/// storage. **One call per destination at a time**: two would write the same
/// part. To give up on a download, or to free its space after a
/// `FileSystemException` such as a full disk, delete the two side files.
///
/// Errors are those of [AssetBundleClient.download], plus the
/// [FileSystemException]s of writing the part; the side files stay for the
/// next call to resume.
Future<AssetDownloadResult> downloadToFile(
  AssetBundleClient bundle,
  String path,
  String destination, {
  void Function(AssetDownloadProgress progress)? onProgress,
  bool noCache = false,
}) async {
  // Refused before anything on disk is touched: a manifest-chosen name may
  // be both the asset path and part of the destination.
  checkPath(path);
  final part = File('$destination.part');
  final etagFile = File('$destination.part.etag');
  await part.parent.create(recursive: true);
  // A side file that is a link would write the plaintext into its target.
  for (final side in <File>[part, etagFile]) {
    if (FileSystemEntity.typeSync(side.path, followLinks: false) ==
        FileSystemEntityType.link) {
      Link(side.path).deleteSync();
    }
  }
  var offset = 0;
  String? savedEtag;
  if (part.existsSync() && etagFile.existsSync()) {
    try {
      final etag = etagFile.readAsStringSync();
      if (etag.isNotEmpty) {
        savedEtag = etag;
        offset = part.lengthSync();
      }
    } on FileSystemException {
      // Not the text this function writes: start over.
    }
  }
  if (offset == 0 && etagFile.existsSync()) etagFile.deleteSync();

  Future<AssetDownloadResult> attempt() async {
    final file = await part.open(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    try {
      final result = await bundle.download(
        path,
        sink: _FileSink(file, () {
          // The part is being emptied for another object: its old ETag must
          // not survive beside the new bytes.
          if (etagFile.existsSync()) etagFile.deleteSync();
          savedEtag = null;
        }),
        resume: offset > 0 && savedEtag != null
            ? AssetResume(offset: offset, etag: savedEtag!)
            : null,
        noCache: noCache,
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
          onProgress?.call(progress);
        },
      );
      await file.flush();
      return result;
    } finally {
      await file.close();
    }
  }

  AssetDownloadResult result;
  try {
    result = await attempt();
  } on ArgumentError catch (e) {
    // A part longer than the file it resumes: nothing to keep. Once more
    // from byte 0. Any other ArgumentError — one `onProgress` threw, say —
    // is the caller's, and the part stays for the next call.
    if (offset == 0 || e.message != resumePastEnd) rethrow;
    offset = 0;
    savedEtag = null;
    if (etagFile.existsSync()) etagFile.deleteSync();
    result = await attempt();
  }
  await part.rename(destination);
  if (etagFile.existsSync()) etagFile.deleteSync();
  return result;
}

final class _FileSink implements AssetSink {
  _FileSink(this._file, this._onReset);

  final RandomAccessFile _file;
  final void Function() _onReset;

  @override
  Future<void> write(Uint8List chunk) async {
    await _file.writeFrom(chunk);
  }

  @override
  Future<void> reset() async {
    _onReset();
    await _file.truncate(0);
    await _file.setPosition(0);
  }
}
