// The `yyt-enc v1` layout: a 40-byte header, then 64 KiB ciphertext segments
// each ending in a 32-byte HMAC-SHA256 tag. Pure arithmetic, no IO and no
// crypto, so every offset rule is testable on its own. The normative text is
// `docs/asset-encryption.md` in the service repository.
import 'dart:typed_data';

/// `0x28` ‖ salt (32) ‖ noncePrefix (7).
const int headerLength = 40;

/// The first byte of every ciphertext: the header length.
const int headerByte = 0x28;

/// HKDF salt bytes in the header.
const int saltLength = 32;

/// Nonce prefix bytes in the header.
const int noncePrefixLength = 7;

/// Ciphertext segment size, tag included.
const int segmentSize = 65536;

/// HMAC-SHA256 tag bytes at the end of every segment.
const int tagLength = 32;

/// Plaintext a full first segment holds: 65,536 − 40 − 32.
const int firstPlain = segmentSize - headerLength - tagLength;

/// Plaintext every full later segment holds: 65,536 − 32.
const int laterPlain = segmentSize - tagLength;

/// An empty file: the header and one empty segment's tag.
const int minCiphertext = headerLength + tagLength;

/// The platform's 256 MiB file ceiling plus the format's overhead (4,099
/// segments): 268,566,664 bytes.
const int maxCiphertext = 256 * 1024 * 1024 + headerLength + tagLength * 4099;

/// The segment count a ciphertext length implies, or `null` when no
/// plaintext encrypts to that length (the caller reports `asset_corrupt`).
int? segmentsOf(int total) {
  if (total < minCiphertext || total > maxCiphertext) return null;
  if (total <= segmentSize) return 1;
  final n = 1 + (total - segmentSize + segmentSize - 1) ~/ segmentSize;
  // The last segment must hold at least one plaintext byte and its tag.
  if (total - segmentSize * (n - 1) < tagLength + 1) return null;
  return n;
}

/// Plaintext length of a well-formed ciphertext of [total] bytes in [n]
/// segments.
int plaintextLengthOf(int total, int n) => total - headerLength - tagLength * n;

/// Ciphertext offset where segment [i] starts.
int cipherStart(int i) => i == 0 ? headerLength : segmentSize * i;

/// Plaintext offset where segment [i] starts.
int plainStart(int i) => i == 0 ? 0 : firstPlain + laterPlain * (i - 1);

/// The segment holding plaintext offset [p].
int segmentOf(int p) => p < firstPlain ? 0 : 1 + (p - firstPlain) ~/ laterPlain;

/// Ciphertext byte range `[start, end)` of segment [i] in a file of [total]
/// bytes. Without [total] it is the nominal extent of a full segment, which is
/// what a request can ask for before the length is known: a server clamps a
/// range that runs past the end.
({int start, int end}) segmentExtent(int i, [int? total]) {
  final start = cipherStart(i);
  final full = start + (i == 0 ? segmentSize - headerLength : segmentSize);
  return (start: start, end: total == null || full < total ? full : total);
}

/// `IV_i = noncePrefix ‖ u32be(i) ‖ last ‖ 0x00000000`.
Uint8List segmentIv(Uint8List noncePrefix, int i, {required bool last}) {
  final iv = Uint8List(16)..setRange(0, noncePrefixLength, noncePrefix);
  ByteData.sublistView(iv).setUint32(noncePrefixLength, i);
  iv[noncePrefixLength + 4] = last ? 1 : 0;
  return iv;
}
