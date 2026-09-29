import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart';

// An independent `yyt-enc v1` encryptor, written from `docs/asset-encryption.md`
// in the service repository rather than from `yingyeothon_asset_client`: HMAC
// and HKDF from `package:crypto`, AES-CTR from pointycastle's
// `SICStreamCipher`, none of which the library's decryptor uses, so the two
// can disagree. The conformance vectors are what prove the library agrees with
// the Go encryptor; this one only has to agree with the spec. It lives here
// because both the asset client's tests and the offline demo encrypt with it.

const int _firstPlain = 65464;
const int _laterPlain = 65504;

Uint8List _hmac(List<int> key, List<List<int>> parts) {
  final sink = _Collect();
  final mac = c.Hmac(c.sha256, key).startChunkedConversion(sink);
  for (final part in parts) {
    mac.add(part);
  }
  mac.close();
  return Uint8List.fromList(sink.digest!.bytes);
}

final class _Collect implements Sink<c.Digest> {
  c.Digest? digest;
  @override
  void add(c.Digest data) => digest = data;
  @override
  void close() {}
}

Uint8List _hkdf(List<int> ikm, List<int> salt, List<int> info, int length) {
  final prk = _hmac(salt.isEmpty ? Uint8List(32) : salt, [ikm]);
  final out = BytesBuilder();
  var t = <int>[];
  for (var i = 1; out.length < length; i++) {
    t = _hmac(prk, [
      t,
      info,
      <int>[i],
    ]);
    out.add(t);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

Uint8List _u32be(int n) => Uint8List(4)..buffer.asByteData().setUint32(0, n);

/// Encrypts [plaintext] under the 32-byte [key] as `yyt-enc v1`, with [ad]
/// as its associated data: the object's path below the bundle
/// (`manifest.json`, `img/a.png`). Deterministic, as the CLI's encryptor is.
Uint8List encryptAsset(Uint8List key, String ad, Uint8List plaintext) {
  final adBytes = utf8.encode(ad);
  final kDet = _hkdf(key, const [], utf8.encode('yyt-enc v1 det'), 32);
  final d = _hmac(kDet, [_u32be(adBytes.length), adBytes, plaintext]);
  final saltPrefix = _hkdf(d, const [], utf8.encode('yyt-enc v1 header'), 39);
  final salt = Uint8List.sublistView(saltPrefix, 0, 32);
  final noncePrefix = Uint8List.sublistView(saltPrefix, 32);
  final km = _hkdf(key, salt, adBytes, 64);
  final kEnc = Uint8List.sublistView(km, 0, 32);
  final kMac = Uint8List.sublistView(km, 32);
  final n = plaintext.length <= _firstPlain
      ? 1
      : 1 + (plaintext.length - _firstPlain + _laterPlain - 1) ~/ _laterPlain;
  final out = BytesBuilder()
    ..addByte(0x28)
    ..add(salt)
    ..add(noncePrefix);
  var at = 0;
  for (var i = 0; i < n; i++) {
    final size = i == 0 ? _firstPlain : _laterPlain;
    final end = at + size < plaintext.length ? at + size : plaintext.length;
    final piece = Uint8List.sublistView(plaintext, at, end);
    at = end;
    final iv = Uint8List(16)
      ..setAll(0, noncePrefix)
      ..setAll(7, _u32be(i))
      ..[11] = i == n - 1 ? 1 : 0;
    final cipher = SICStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(kEnc), iv));
    final body = cipher.process(piece);
    out
      ..add(body)
      ..add(_hmac(kMac, [iv, body]));
  }
  return out.takeBytes();
}

/// The `yak1.` text form of a 32-byte key, as `yyt asset key show` prints it
/// and `AssetBundleClientOptions.key` takes it.
String assetKeyText(Uint8List key) {
  if (key.length != 32) throw ArgumentError('an asset key is 32 bytes');
  return 'yak1.${base64Url.encode(key).replaceAll('=', '')}';
}
