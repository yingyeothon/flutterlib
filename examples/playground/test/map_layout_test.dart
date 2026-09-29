import 'package:flutter_test/flutter_test.dart';
import 'package:yyt_playground/map_layout.dart';

void main() {
  test('reads name, size, zones and blocked cells', () {
    final layout = MapLayout.parse(<String, Object?>{
      'name': 'arena',
      'width': 16,
      'height': 12,
      'zones': <Object?>['A', 'B'],
      'blocked': <Object?>[
        <Object?>[3, 4],
        <Object?>[15, 11],
      ],
    });
    expect(layout.name, 'arena');
    expect((layout.width, layout.height), (16, 12));
    expect(layout.zones, ['A', 'B']);
    expect(layout.blocked, {(3, 4), (15, 11)});
    expect(layout.isBlocked(3, 4), isTrue);
    expect(layout.isBlocked(4, 4), isFalse);
    expect(layout.summary, '16x12, 2 zone(s), 2 blocked');
  });

  test('anything that is not the expected shape falls back per field', () {
    for (final doc in <Object?>[null, 'text', 7, <Object?>[]]) {
      final layout = MapLayout.parse(doc);
      expect(layout.name, MapLayout.fallback.name);
      expect((layout.width, layout.height), (20, 20));
      expect(layout.zones, isEmpty);
      expect(layout.blocked, isEmpty);
    }
    // The fake gateway's default document: a name and zones, no size.
    final fake = MapLayout.parse(<String, Object?>{
      'name': 'fake',
      'zones': <Object?>['Zone001', 'Zone002'],
    });
    expect((fake.name, fake.width, fake.height), ('fake', 20, 20));
    expect(fake.zones, ['Zone001', 'Zone002']);
  });

  test('sides are bounded on both edges; bad cells are dropped', () {
    MapLayout side(Object? w) =>
        MapLayout.parse(<String, Object?>{'width': w, 'height': w});
    expect(side(1).width, 1);
    expect(side(MapLayout.maxSide).width, MapLayout.maxSide);
    expect(side(0).width, 20);
    expect(side(MapLayout.maxSide + 1).width, 20);
    expect(side(4.0).width, 20);
    final layout = MapLayout.parse(<String, Object?>{
      'width': 4,
      'height': 4,
      'blocked': <Object?>[
        <Object?>[4, 0], // outside
        <Object?>[0, -1], // outside
        <Object?>[1], // not a pair
        <Object?>[1.0, 2], // not ints
        'cell',
        <Object?>[3, 3],
        <Object?>[3, 3], // twice
      ],
    });
    expect(layout.blocked, {(3, 3)});
  });

  test('a zone is kept exactly as written, or dropped; never rewritten', () {
    final layout = MapLayout.parse(<String, Object?>{
      'zones': <Object?>[
        'A',
        '',
        1,
        'A', // a duplicate would be a duplicate widget key
        'x' * 64, // at the gateway's 64-byte cap
        'x' * 65, // over it
        '한' * 21, // 63 bytes
        '한' * 22, // 66 bytes
        'tab\there',
        'rtl\u202Eevil',
        'iso\u2066late',
        'A\u200B', // looks like A
        'A\uFEFF',
        'alm\u061C',
        'line\u2028break',
        'lone\uD800',
        'tag\u{E0041}',
        'A\uFE0F', // looks like A
        'A\u3164',
        'vs\u{E0100}',
        'B',
      ],
    });
    expect(layout.zones, ['A', 'x' * 64, '한' * 21, 'B']);
  });

  test('zones stop at maxZones', () {
    final many = MapLayout.parse(<String, Object?>{
      'zones': <Object?>[for (var i = 0; i < 100000; i++) 'z$i'],
    });
    expect(many.zones, [for (var i = 0; i < MapLayout.maxZones; i++) 'z$i']);
  });

  test('a name the UI could not show as written falls back', () {
    String name(Object? n) =>
        MapLayout.parse(<String, Object?>{'name': n}).name;
    expect(name('arena'), 'arena');
    expect(name('n' * MapLayout.maxNameRunes), 'n' * MapLayout.maxNameRunes);
    for (final bad in <Object?>[
      '',
      'n' * (MapLayout.maxNameRunes + 1),
      'bell\u0007',
      'del\u007F',
      'c1\u0085',
      'lrm\u200E',
      'rlo\u202E',
      'pdi\u2069',
      7,
    ]) {
      expect(name(bad), MapLayout.fallback.name, reason: '$bad');
    }
    // Characters, not UTF-16 units: 32 emoji fit.
    expect(name('😀' * 32), '😀' * 32);
  });
}
