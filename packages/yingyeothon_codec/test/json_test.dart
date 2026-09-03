import 'dart:convert' as convert;

import 'package:test/test.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';

String nested(int depth) => '${'[' * depth}${']' * depth}';

void main() {
  group('tryDecode length cap', () {
    test('accepts exactly maxLength characters', () {
      final text = '"${'a' * (Json.maxLength - 2)}"';
      expect(text.length, Json.maxLength);
      expect(Json.tryDecode(text), isA<JsonDecoded>());
    });

    test('refuses maxLength + 1 before parsing', () {
      final text = '"${'a' * (Json.maxLength - 1)}"';
      final result = Json.tryDecode(text);
      expect(result, isA<JsonRefused>());
      final failure = (result as JsonRefused).failure;
      expect(failure.error, JsonParseError.inputTooLong);
      expect(failure.offset, Json.maxLength);
    });

    test('tryDecodeBig accepts above maxLength and refuses above its cap', () {
      final big = '"${'a' * Json.maxLength}"';
      expect(Json.tryDecode(big), isA<JsonRefused>());
      expect(Json.tryDecodeBig(big), isA<JsonDecoded>());
      expect(Json.tryDecodeBig(big, maxLength: 16), isA<JsonRefused>());
    });

    test('tryDecodeBig refuses a cap above maxBigLength', () {
      expect(
        () => Json.tryDecodeBig('1', maxLength: Json.maxBigLength + 1),
        throwsArgumentError,
      );
    });
  });

  group('depth cap', () {
    test('accepts depth 64 and refuses 65 on decode', () {
      expect(Json.tryDecode(nested(Json.maxDepth)), isA<JsonDecoded>());
      final result = Json.tryDecode(nested(Json.maxDepth + 1));
      expect(result, isA<JsonRefused>());
      expect(
        (result as JsonRefused).failure.error,
        JsonParseError.depthExceeded,
      );
    });

    test('accepts depth 64 and refuses 65 on encode', () {
      Object? build(int depth) {
        Object? v = <Object?>[];
        for (var i = 1; i < depth; i++) {
          v = <Object?>[v];
        }
        return v;
      }

      expect(Json.encode(build(Json.maxDepth)), nested(Json.maxDepth));
      expect(
        () => Json.encode(build(Json.maxDepth + 1)),
        throwsA(isA<JsonDepthError>()),
      );
    });

    test('depthOf counts objects and arrays, scalars are 0', () {
      expect(Json.depthOf(1), 0);
      expect(Json.depthOf(<String, Object?>{}), 1);
      expect(
        Json.depthOf(<String, Object?>{
          'a': <Object?>[
            <String, Object?>{'b': 1},
          ],
        }),
        3,
      );
    });
  });

  group('failures never quote the input', () {
    const bad = '{"secret":"eyJ.secret-token.sig",';

    test('malformed reports a code and an offset only', () {
      final result = Json.tryDecode(bad);
      expect(result, isA<JsonRefused>());
      final failure = (result as JsonRefused).failure;
      expect(failure.error, JsonParseError.malformed);
      expect(failure.offset, greaterThanOrEqualTo(0));
      expect(failure.toString(), '${failure.error.name} at ${failure.offset}');
    });

    test('positive control: dart:convert itself does quote the input', () {
      // If this ever stops holding, the wrapper's reason for existing changed.
      expect(
        () => convert.jsonDecode(bad),
        throwsA(
          predicate((Object e) {
            return e is FormatException &&
                e.toString().contains('secret-token');
          }),
        ),
      );
    });

    test('decode throws JsonParseException whose text is the template', () {
      expect(
        () => Json.decode(bad),
        throwsA(
          predicate((Object e) {
            if (e is! JsonParseException) return false;
            final f = e.failure;
            return e.toString() ==
                'JsonParseException: ${f.error.name} at ${f.offset}';
          }),
        ),
      );
    });

    test('a bad document leaves no state behind for the next good one', () {
      for (var i = 0; i < 3; i++) {
        expect(Json.tryDecode('{'), isA<JsonRefused>());
        expect(Json.decode('{"ok":true}'), <String, Object?>{'ok': true});
      }
    });
  });

  group('encode', () {
    test('pins number and string output bytes', () {
      expect(Json.encode(1e21), '1e+21');
      expect(Json.encode(-0.0), '-0.0');
      expect(Json.encode(1e-320), '1e-320');
      expect(Json.encode(1.5), '1.5');
      expect(Json.encode(3), '3');
      expect(Json.encode('a"b\\c\n'), r'"a\"b\\c\n"');
      expect(Json.encode('한글'), '"한글"');
    });

    test('an unpaired surrogate is escaped so the text survives UTF-8', () {
      final text = Json.encode('\ud800x');
      expect(text, r'"\ud800x"');
      expect(convert.utf8.decode(convert.utf8.encode(text)), text);
    });

    test('refuses NaN and infinity without naming them', () {
      expect(() => Json.encode(double.nan), throwsA(isA<JsonEncodeError>()));
      expect(
        () => Json.encode(<String, Object?>{'x': double.infinity}),
        throwsA(
          predicate(
            (Object e) =>
                e is JsonEncodeError && !e.toString().contains('Infinity'),
          ),
        ),
      );
    });

    test('refuses an unsupported object and names its kind only', () {
      expect(
        () => Json.encode(Object()),
        throwsA(
          predicate((Object e) => e is JsonEncodeError && e.kind == 'Object'),
        ),
      );
    });

    test('round-trips a deterministic corpus through UTF-8', () {
      final corpus = <Object?>[
        null,
        true,
        0,
        -1,
        1.25,
        '',
        'plain',
        'quote " backslash \\ tab \t emoji 😀 hangul 한',
        'control \u0000\u001f',
        <Object?>[
          1,
          'two',
          <String, Object?>{'three': 3.0},
        ],
        <String, Object?>{
          'a': null,
          'b': <Object?>[],
          'c': <String, Object?>{},
        },
      ];
      for (final value in corpus) {
        final bytes = convert.utf8.encode(Json.encode(value));
        expect(Json.decode(convert.utf8.decode(bytes)), value);
      }
    });
  });

  group('JsonObjectBuilder', () {
    test('set(null) omits the key, setNull writes null', () {
      final built = Json.object()
          .set('a', 1)
          .set('gone', null)
          .setNull('explicit')
          .build();
      expect(built.containsKey('gone'), isFalse);
      expect(built.containsKey('explicit'), isTrue);
      expect(built['explicit'], isNull);
      expect(Json.encode(built), '{"a":1,"explicit":null}');
    });

    test('set(null) removes a key set earlier', () {
      expect(Json.object().set('a', 1).set('a', null).build(), isEmpty);
    });

    test('build returns a snapshot', () {
      final builder = Json.object().set('a', 1);
      final first = builder.build();
      builder.set('b', 2);
      expect(first, <String, Object?>{'a': 1});
    });
  });

  group('JsonReading', () {
    final obj = Json.decode(
      '{"s":"x","n":1.5,"i":2,"whole":3.0,"b":true,'
      '"o":{"k":1},"l":[1],"z":null}',
    ) as JsonObject;

    test('distinguishes absent from null', () {
      expect(obj.has('z'), isTrue);
      expect(obj.has('missing'), isFalse);
      expect(obj.getString('z'), isNull);
      expect(obj.getString('missing'), isNull);
    });

    test('reads each type and rejects the wrong type as null', () {
      expect(obj.getString('s'), 'x');
      expect(obj.getString('n'), isNull);
      expect(obj.getNumber('n'), 1.5);
      expect(obj.getInt('i'), 2);
      expect(obj.getInt('whole'), 3);
      expect(obj.getInt('n'), isNull);
      expect(obj.getDouble('i'), 2.0);
      expect(obj.getBool('b'), isTrue);
      expect(obj.getBool('s'), isNull);
      expect(obj.getObject('o'), <String, Object?>{'k': 1});
      expect(obj.getObject('l'), isNull);
      expect(obj.getListOrEmpty('l'), <Object?>[1]);
      expect(obj.getListOrEmpty('o'), isEmpty);
      expect(obj.getListOrEmpty('missing'), isEmpty);
    });
  });
}
