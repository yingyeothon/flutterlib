/// Reader for yyt asset bundles on the CDN.
///
/// An [AssetBundleClient] reads one bundle: a whole file, a JSON manifest, a
/// byte range, or a resumable download into an [AssetSink] the caller
/// provides. With the bundle's key it reads an encrypted bundle, whose files
/// the CDN serves as `yyt-enc v1` ciphertext, and verifies every 64 KiB
/// segment before releasing a byte of it; without a key it reads a plain
/// bundle through the same calls. Pure Dart: it runs on every platform,
/// web included. A download straight to a file is in
/// `yingyeothon_asset_client_io.dart`, which needs `dart:io`.
///
/// Nothing here ever logs, throws or returns a message that contains the
/// key, a URL or a byte of plaintext; a path appears only as a sanitised log
/// field.
library;

export 'src/asset_bundle_client.dart'
    show AssetBundleClient, AssetBundleClientOptions;
export 'src/errors.dart' show AssetClientErrorCode, AssetClientException;
export 'src/types.dart'
    show AssetDownloadProgress, AssetDownloadResult, AssetResume, AssetSink;
