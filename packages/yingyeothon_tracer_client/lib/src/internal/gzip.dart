// Gzip where `dart:io` exists; plain bodies on web (the ingest accepts both).
export 'gzip_stub.dart' if (dart.library.io) 'gzip_io.dart';
