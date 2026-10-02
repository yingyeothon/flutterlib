# Asset client: verified file downloads

Status: planned; no SDK implementation changes in this task.

## Goal

Let Powerphone use `yingyeothon_asset_client` for manifest reads and resumable
downloads without losing its existing integrity checks and recovery behavior.
Keep generic transfer and file finalization in this library. Keep SQLite access,
manifest persistence, required/optional content policy, and playlist availability
in the consuming app.

The requested location of this task file is an explicit exception to the usual
rule against root-level tracking documents. Remove it when the work is complete;
move lasting consumer guidance into the existing asset documentation.

## Current implementation and gaps

- `AssetBundleClient.download` already streams to an `AssetSink`, supports ETag
  resume, progress, response/body-idle timeouts, and encrypted segment verification.
- `downloadToFile` in
  `packages/yingyeothon_asset_client/lib/yingyeothon_asset_client_io.dart` writes
  `<destination>.part`, records `<destination>.part.etag`, flushes and closes the
  part, then renames it over the destination.
- The helper does not accept an expected plaintext SHA-256, expected plaintext
  length, or a pre-rename validator. A plain transfer's HTTP length and ETag do not
  verify its bytes against the app's manifest. Encrypted segment authentication
  also does not validate an application's SQLite schema or local resumed prefix.
- File-system failures leave the side files in place. The consumer currently
  must remove them itself to release space after a local write failure.
- A fully received part still needs a network request to finish the SDK's resume
  path. Powerphone can currently verify and promote a complete part offline.
- SDK/network errors and local I/O or consumer callback errors have different
  contracts. Powerphone currently maps all download failures to one app error so
  a failed optional file does not abort downloads of unrelated files.

References: the package's [README](packages/yingyeothon_asset_client/README.md),
[file helper](packages/yingyeothon_asset_client/lib/yingyeothon_asset_client_io.dart),
[client](packages/yingyeothon_asset_client/lib/src/asset_bundle_client.dart), and
[asset guide](docs/assets.md). Compare with the consumer repository's
`lib/db/download.dart`, `lib/db/content_repository.dart`, and their tests before
implementing; do not move their SQLite-specific logic into this package.

## SDK work

- [ ] Design optional expected plaintext size and SHA-256 inputs, plus an async
  pre-commit file validator, for the I/O download helper. The exact API is to be
  reviewed against `CONVENTIONS.md`; these are requirements, not existing symbols.
  Keep `dart:io` out of the core library and preserve existing callers' behavior
  when the new options are omitted.
- [ ] Validate options before touching files or sending requests. Bound received
  plaintext by the expected size when provided. Verify the complete file's size
  and SHA-256, including bytes recovered from an earlier partial download.
  Define empty-file behavior and avoid loading large files into memory.
- [ ] Run the consumer validator after byte integrity checks and after closing the
  writable file handle, but before rename. The app can open and close SQLite here.
  Only a successful verification and validation may replace the destination.
- [ ] Add a no-network completion path for a part whose size matches a trusted
  manifest's expected size: hash the whole part, run the validator, then promote
  it. Require the expected digest for this shortcut; size or ETag alone is not
  proof. For encrypted bundles the digest describes plaintext, not the platform's
  ciphertext checksum. Do not weaken the existing authenticated download path
  when this trusted manifest contract is absent.
- [ ] Specify and implement an opt-in failure cleanup policy for verified file
  downloads; retain the existing side-file retention behavior by default for
  callers that do not select it. Preserve resumable parts on network
  interruption, timeout, and user cancellation. Discard unusable parts and their
  ETag sidecars after confirmed content corruption or local write/flush failure
  such as disk exhaustion. Define separately how validator rejection, validator
  execution failure, rename failure, and sidecar cleanup failure are reported;
  do not blanket-delete valid downloads for every exception.
- [ ] Keep the prior destination intact on transfer, verification, and validation
  failure. A cleanup error must not mask the primary failure; define the result
  when rename succeeded but sidecar deletion failed.
- [ ] Define public failure codes/types for the new integrity checks without
  leaking paths, URLs, keys, file content, or arbitrary exception text through
  SDK-generated messages. Preserve documented consumer callback error behavior,
  and document how apps can translate SDK, local I/O, and cancellation failures.
- [ ] Document cancellation and ownership. Existing cancellation through a sink
  or progress callback stops when work next reaches that callback; a quiet
  connection is bounded by its timeout. Evaluate a per-download cancellation
  seam if immediate cancellation is required, without closing a shared bundle
  client or breaking independent reads. Powerphone currently closes a caller-owned
  HTTP client to cancel a download: select either a dedicated client per cancellable
  operation or a per-download cancellation API, and test cancellation latency on a
  stalled connection and the ability to retry afterward.

## Acceptance tests

- [ ] Plain and encrypted successful downloads: correct size/digest, validation
  before rename, replacement only after success, bounded memory usage.
- [ ] Wrong size, wrong digest, corrupt resumed prefix, and rejected validation:
  no replacement of the existing destination; cleanup follows the documented
  failure category. Include an encrypted resume with a modified local prefix.
- [ ] Complete valid part succeeds without any HTTP call; a same-size corrupt
  part is never promoted. Include a crash after receiving the final byte and
  before finalization, and a complete part with a missing ETag sidecar. Define
  and test the final progress notification and result on offline completion;
  never invent an ETag when no sidecar exists.
- [ ] Interrupted downloads retain usable partial bytes and resume correctly;
  changed ETags reset safely, including hash state. Plain downloads reset when
  Range is ignored; preserve encrypted downloads' documented rejection when the
  host ignores Range rather than signaling an object change.
- [ ] Deterministically inject disk write/flush failures rather than filling the
  host disk. Check sidecar cleanup and that the original exception is preserved.
- [ ] Exercise validator exceptions, rename failure, post-rename sidecar cleanup
  failure, cancellation, and the existing one-writer-per-destination contract.
- [ ] Verify SDK-generated logs and errors disclose no sensitive inputs.
- [ ] Keep existing plain/encrypted, browser, and encryption-vector tests green.
  Update public API documentation and barrel exports if the new design needs
  public symbols; update the asset guide's integration recipe.
- [ ] Run the repository gate and appropriate manual verification for the final
  implementation. Verify a consumer installs the selected release/commit and
  compiles; the current package requires Dart 3.13 or newer.

## Consumer integration after the SDK work

These are Powerphone follow-ups, not permission to edit or deploy that app as part
of this SDK task.

- [ ] Use a platform live bundle with immutable content-addressed databases and
  mutable `selects.json`; publish through `yyt asset sync` after source/build
  validation. Plain assets suffice for the current migration.
- [ ] Read the manifest with `readJson`, validate its app schema, and retain the
  existing immediate local commit and offline fallback behavior.
- [ ] Replace the custom HTTP downloader with the verified SDK helper, providing
  plaintext digest/size and a SQLite validation callback. Keep error translation
  at the app boundary so optional failures remain non-fatal.
- [ ] Update deletion/orphan cleanup for `.part` and `.part.etag`. Choose an explicit
  migration policy for legacy `.download` files that have no saved ETag, while
  preserving valid completed content-addressed databases.
- [ ] Preserve progress, cancellation, per-file serialization, required content,
  on-demand music downloads, and database-handle closure before file deletion.
- [ ] Re-run the app's download, repository, music, and offline regression tests.
  Verify interrupted large downloads, low storage, and offline startup on device.

## Separate follow-up

Extracting MP3 blobs from playlist SQLite files into individual immutable assets
can reduce playlist-wide downloads and duplicate media storage. That changes the
consumer's content format, caching, and offline playback policy; it is not a
prerequisite for the verified downloader and is outside this task.
