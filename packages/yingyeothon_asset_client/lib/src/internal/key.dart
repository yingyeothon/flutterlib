import 'dart:typed_data';

import '../errors.dart';

const String _prefix = 'yak1.';
const int _textLength = 43;
const int _keyBytes = 32;
const String _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

String _encode(Uint8List bytes) {
  final out = StringBuffer();
  var i = 0;
  for (; i + 3 <= bytes.length; i += 3) {
    final n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out
      ..write(_alphabet[(n >> 18) & 63])
      ..write(_alphabet[(n >> 12) & 63])
      ..write(_alphabet[(n >> 6) & 63])
      ..write(_alphabet[n & 63]);
  }
  final rest = bytes.length - i;
  if (rest == 1) {
    final n = bytes[i] << 16;
    out
      ..write(_alphabet[(n >> 18) & 63])
      ..write(_alphabet[(n >> 12) & 63]);
  } else if (rest == 2) {
    final n = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out
      ..write(_alphabet[(n >> 18) & 63])
      ..write(_alphabet[(n >> 12) & 63])
      ..write(_alphabet[(n >> 6) & 63]);
  }
  return out.toString();
}

/// Lenient on purpose: the re-encode comparison is what makes it strict.
Uint8List? _decode(String text) {
  final out = Uint8List(text.length * 6 ~/ 8);
  var bits = 0;
  var value = 0;
  var at = 0;
  for (final unit in text.codeUnits) {
    final digit = unit < 128
        ? _alphabet.indexOf(String.fromCharCode(unit))
        : -1;
    if (digit < 0) {
      out.fillRange(0, out.length, 0);
      return null;
    }
    value = ((value << 6) | digit) & 0xffffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[at++] = (value >> bits) & 0xff;
    }
  }
  return out;
}

const AssetClientException _badKey = AssetClientException(
  AssetClientErrorCode.badKey,
);

/// A private copy of the 32 key bytes, from the text form (`yak1.` + 43
/// base64url characters that decode to 32 bytes and re-encode to the same
/// text) or from 32 raw bytes. Anything else is `bad_key`, and the exception
/// never quotes what it was given.
Uint8List parseAssetKey(Object key) {
  if (key is Uint8List) {
    if (key.length != _keyBytes) throw _badKey;
    return Uint8List.fromList(key);
  }
  if (key is! String ||
      key.length != _prefix.length + _textLength ||
      !key.startsWith(_prefix)) {
    throw _badKey;
  }
  final text = key.substring(_prefix.length);
  final raw = _decode(text);
  if (raw == null) throw _badKey;
  if (raw.length != _keyBytes) {
    raw.fillRange(0, raw.length, 0);
    throw _badKey;
  }
  // Only 16 of the 64 characters can end a canonical 32-byte encoding; the
  // other 48 decode to the same bytes as one of them, and must not be keys.
  if (_encode(raw) != text) {
    raw.fillRange(0, raw.length, 0);
    throw _badKey;
  }
  return raw;
}
