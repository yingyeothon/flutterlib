import 'dart:convert';
import 'dart:typed_data';

// The encryptor is the fake gateway's (`asset_encryption.dart`, no dart:io,
// so the browser run can use it too): written from the service's
// `docs/asset-encryption.md`, sharing nothing with this library above the AES
// block cipher.
export 'package:yingyeothon_fake_gateway/asset_encryption.dart'
    show encryptAsset;

/// Deterministic, non-repeating-looking bytes.
Uint8List pattern(int length, [int seed = 7]) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + seed + (i >> 8)) & 0xff;
  }
  return out;
}

/// 32 key bytes and their `yak1.` text form.
({Uint8List bytes, String text}) testKey(int fill) {
  final bytes = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    bytes[i] = (i * 13 + fill) & 0xff;
  }
  final text = base64Url.encode(bytes).replaceAll('=', '');
  return (bytes: bytes, text: 'yak1.$text');
}
