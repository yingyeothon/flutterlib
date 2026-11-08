import 'dart:typed_data';

/// Whether [gzipBytes] compresses on this platform.
const bool gzipAvailable = false;

/// Returns [bytes] unchanged: no `dart:io` here.
Uint8List gzipBytes(Uint8List bytes) => bytes;
