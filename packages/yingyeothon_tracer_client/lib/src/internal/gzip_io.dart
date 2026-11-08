import 'dart:io';
import 'dart:typed_data';

/// Whether [gzipBytes] compresses on this platform.
const bool gzipAvailable = true;

/// Gzips [bytes].
Uint8List gzipBytes(Uint8List bytes) => Uint8List.fromList(gzip.encode(bytes));
