/// The `yyt-enc v1` encryptor behind the fake CDN, without `dart:io`, so a
/// test that also runs in a browser can build ciphertext with it. For tests
/// and the offline demo only; the platform's own encryptor is the CLI's.
library;

export 'src/asset_encryption.dart' show assetKeyText, encryptAsset;
