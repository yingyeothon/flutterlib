// Prints the package directories under packages/, one per line: the pure
// Dart ones by default, the Flutter ones with `--flutter`. tool/gate.sh and
// CI use it so `dart analyze` and `dart test` never see a Flutter package.
//
//   dart run tool/bin/list_packages.dart [--flutter]
import 'dart:io';

import 'package:yyt_tool/src/packages.dart';

void main(List<String> args) {
  final flutter = args.contains('--flutter');
  final dirs = Directory('packages').listSync().whereType<Directory>().where((
    d,
  ) {
    final pubspec = File('${d.path}/pubspec.yaml');
    return pubspec.existsSync() &&
        isFlutterPubspec(pubspec.readAsStringSync()) == flutter;
  }).toList()..sort((a, b) => a.path.compareTo(b.path));
  for (final d in dirs) {
    print('${d.path}/');
  }
}
