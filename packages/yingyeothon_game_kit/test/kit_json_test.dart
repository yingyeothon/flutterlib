import 'package:test/test.dart';
import 'package:yingyeothon_game_kit/yingyeothon_game_kit.dart';

void main() {
  test('shared Wave A vectors use canonical UTF-8 SHA-256', () {
    const zero =
        '0000000000000000000000000000000000000000000000000000000000000000';
    expect(
      KitJson.hash([
        zero,
        0,
        'alice',
        {'y': 2, 'x': 1},
      ]),
      '8e48ac7f284692548995d918cbc6328694734bef04eb5dad33144fcd7d300c2a',
    );
    expect(
      KitJson.hash([
        zero,
        1,
        'alice',
        {'text': '안녕', 'ok': true},
      ]),
      'de6d3a87f5523e1f59808cb6072bafefb66db18938fabcf516fd808549607935',
    );
  });
  test('ECMAScript number notation and UTF-16 key order', () {
    for (final entry in <num, String>{
      0: '0',
      -0.0: '0',
      1: '1',
      1.5: '1.5',
      1e-6: '0.000001',
      1e-7: '1e-7',
      1e20: '100000000000000000000',
      1e21: '1e+21',
      -1e21: '-1e+21',
      0.02: '0.02',
      123.45: '123.45',
    }.entries) {
      expect(KitJson.canonical(entry.key), entry.value);
    }
    expect(
      KitJson.canonical({'z': null, 'a': false, 'b': true}),
      ' {"a":false,"b":true,"z":null}'.trim(),
    );
    expect(KitJson.canonical(['a\nb', '😀']), '["a\\nb","😀"]');
    expect(KitJson.bytes('한'), 5);
    final source = {
      'a': [1, 2],
    };
    final copy = KitJson.copy(source) as Map;
    (source['a']! as List).add(3);
    expect(copy, {
      'a': [1, 2],
    });
  });
  test('invalid Unicode, cycles, custom serializers and nonfinite values refuse safely', () {
    final cycle = <Object?>[];
    cycle.add(cycle);
    for (final value in [
      double.nan,
      double.infinity,
      Object(),
      String.fromCharCode(0xd800),
      String.fromCharCode(0xdc00),
      cycle,
      9007199254740993,
    ]) {
      expect(() => KitJson.canonical(value), throwsArgumentError);
    }
  });
}
