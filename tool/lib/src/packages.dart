/// Package classification shared by the gate scripts.
library;

import 'package:yaml/yaml.dart';

/// Whether a pubspec declares `flutter: sdk: flutter` under `dependencies`:
/// such a package is outside the workspace and is tested with `flutter test`
/// (rules/tooling.md). A pubspec that does not parse counts as pure Dart, so
/// the Dart steps still see it and fail loudly.
bool isFlutterPubspec(String pubspec) {
  final Object? yaml;
  try {
    yaml = loadYaml(pubspec);
  } on YamlException {
    return false;
  }
  if (yaml is! YamlMap) return false;
  final deps = yaml['dependencies'];
  if (deps is! YamlMap) return false;
  final flutter = deps['flutter'];
  return flutter is YamlMap && flutter['sdk'] == 'flutter';
}
