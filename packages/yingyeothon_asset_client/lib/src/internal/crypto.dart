import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../errors.dart';
import 'format.dart';

/// `asset_corrupt`, with the status of the answer that carried the bytes.
AssetClientException corrupt([int status = 0]) =>
    AssetClientException(AssetClientErrorCode.assetCorrupt, status: status);

Uint8List _hmac(Uint8List key, List<Uint8List> parts) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
  for (final part in parts) {
    mac.update(part, 0, part.length);
  }
  final out = Uint8List(mac.macSize);
  mac.doFinal(out, 0);
  return out;
}

/// HKDF-SHA256 (RFC 5869) for up to 255 × 32 bytes.
Uint8List hkdfSha256(
  Uint8List ikm,
  Uint8List salt,
  Uint8List info,
  int length,
) {
  final prk = _hmac(salt, <Uint8List>[ikm]);
  final out = Uint8List(length);
  var previous = Uint8List(0);
  for (var i = 0, at = 0; at < length; i++) {
    final next = _hmac(prk, <Uint8List>[
      previous,
      info,
      Uint8List.fromList(<int>[i + 1]),
    ]);
    previous.fillRange(0, previous.length, 0);
    previous = next;
    final take = length - at < previous.length ? length - at : previous.length;
    out.setRange(at, at + take, previous);
    at += take;
  }
  prk.fillRange(0, prk.length, 0);
  previous.fillRange(0, previous.length, 0);
  return out;
}

/// XOR-accumulates every byte: the time does not depend on where two tags
/// differ.
bool constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// The bundle key, held until [close].
final class BundleCrypto {
  /// Takes ownership of [key] (32 bytes); [close] zeroes it.
  BundleCrypto(Uint8List key) : _key = key;

  Uint8List? _key;
  final Set<Decryptor> _live = <Decryptor>{};

  /// Whether [close] was called.
  bool get isClosed => _key == null;

  /// Checks the header byte and the total length and derives the segment
  /// keys. Never recomputes the plaintext digest: a decryptor cannot tell a
  /// derived salt from a random one and does not need to.
  Decryptor openDecryptor(Uint8List header, int total, String ad) {
    final key = _key;
    if (key == null) throw StateError('asset client is closed');
    final segments = segmentsOf(total);
    if (segments == null ||
        header.length != headerLength ||
        header[0] != headerByte) {
      throw corrupt();
    }
    final salt = Uint8List.sublistView(header, 1, 1 + saltLength);
    final noncePrefix = Uint8List.fromList(
      Uint8List.sublistView(header, 1 + saltLength, headerLength),
    );
    final okm = hkdfSha256(key, salt, Uint8List.fromList(utf8.encode(ad)), 64);
    final decryptor = Decryptor._(
      this,
      total,
      segments,
      noncePrefix,
      Uint8List.fromList(Uint8List.sublistView(okm, 0, 32)),
      Uint8List.fromList(Uint8List.sublistView(okm, 32, 64)),
    );
    okm.fillRange(0, okm.length, 0);
    _live.add(decryptor);
    return decryptor;
  }

  /// Zeroes and drops the key and every open decryptor's derived keys; a
  /// later [openDecryptor] throws, and so does a decryptor already open at
  /// its next segment.
  void close() {
    final key = _key;
    if (key != null) key.fillRange(0, key.length, 0);
    _key = null;
    for (final d in List<Decryptor>.of(_live)) {
      d.close();
    }
  }
}

/// One file's verified view: its segment count and each segment's plaintext.
final class Decryptor {
  Decryptor._(
    this._crypto,
    this.total,
    this.segments,
    this._noncePrefix,
    this._encKey,
    this._macKey,
  ) : _aes = AESEngine()..init(true, KeyParameter(_encKey));

  final BundleCrypto _crypto;
  final Uint8List _noncePrefix;
  final Uint8List _encKey;
  final Uint8List _macKey;
  final AESEngine _aes;

  /// The ciphertext length.
  final int total;

  /// The segment count [total] implies.
  final int segments;

  /// The plaintext length [total] implies.
  int get plaintextLength => plaintextLengthOf(total, segments);

  /// Verifies segment [i] — exactly the ciphertext bytes of its extent, tag
  /// included — and only then decrypts it. A mismatch is `asset_corrupt`.
  Uint8List open(int i, Uint8List segment) {
    // A read already in flight when the client closed stops here instead of
    // decrypting on with the derived keys.
    if (_crypto.isClosed) throw StateError('asset client is closed');
    final extent = segmentExtent(i, total);
    if (i < 0 || i >= segments || segment.length != extent.end - extent.start) {
      throw corrupt();
    }
    final iv = segmentIv(_noncePrefix, i, last: i == segments - 1);
    final body = Uint8List.sublistView(segment, 0, segment.length - tagLength);
    final tag = Uint8List.sublistView(segment, segment.length - tagLength);
    // Verified before a single byte is decrypted.
    if (!constantTimeEquals(_hmac(_macKey, <Uint8List>[iv, body]), tag)) {
      throw corrupt();
    }
    return _ctr(iv, body);
  }

  /// AES-256-CTR from [iv]: only the last 4 bytes count up, big-endian. A
  /// segment is at most 4,096 blocks, so they never wrap.
  Uint8List _ctr(Uint8List iv, Uint8List input) {
    final out = Uint8List(input.length);
    final counter = Uint8List.fromList(iv);
    final stream = Uint8List(16);
    final view = ByteData.sublistView(counter);
    for (var at = 0; at < input.length; at += 16) {
      _aes.processBlock(counter, 0, stream, 0);
      final n = input.length - at < 16 ? input.length - at : 16;
      for (var j = 0; j < n; j++) {
        out[at + j] = input[at + j] ^ stream[j];
      }
      view.setUint32(12, view.getUint32(12) + 1);
    }
    stream.fillRange(0, 16, 0);
    return out;
  }

  /// Zeroes the derived keys this decryptor holds. The AES engine's expanded
  /// key schedule and the HMAC pads are pointycastle's own and are not
  /// reachable to clear; they go with the object.
  void close() {
    _encKey.fillRange(0, _encKey.length, 0);
    _macKey.fillRange(0, _macKey.length, 0);
    _crypto._live.remove(this);
  }
}
