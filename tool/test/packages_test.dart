import 'package:test/test.dart';
import 'package:yyt_tool/src/packages.dart';

void main() {
  test('a Flutter package declares the flutter sdk dependency', () {
    expect(
      isFlutterPubspec(
        'name: a\ndependencies:\n  flutter:\n    sdk: flutter\n',
      ),
      isTrue,
    );
  });

  test('a pure Dart package, a dev-only flutter_test or junk is not', () {
    for (final pubspec in [
      'name: a\ndependencies:\n  http: ^1.6.0\n',
      'name: a\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n',
      'name: a\n',
      'name: a\ndependencies:\n  flutter: ^1.0.0\n',
      '- not a map',
      'name: [unclosed',
    ]) {
      expect(isFlutterPubspec(pubspec), isFalse, reason: pubspec);
    }
  });
}
