import 'dart:convert';

/// What the playground reads out of the lobby's map asset (`lobby.map()`).
///
/// The document is the game's own format; the gateway only serves its URL.
/// This app understands `{name, width, height, zones: [..], blocked: [[x, y]]}`
/// and falls back per field, so any JSON renders as something and a map
/// change is an edit of that document, not of this code.
class MapLayout {
  const MapLayout({
    required this.name,
    required this.width,
    required this.height,
    required this.zones,
    required this.blocked,
  });

  /// Parses [document]; any field that is missing or out of range takes the
  /// [fallback] value.
  factory MapLayout.parse(Object? document) {
    final doc = document is Map<String, Object?> ? document : null;
    final name = doc?['name'];
    final width = _side(doc?['width']) ?? fallback.width;
    final height = _side(doc?['height']) ?? fallback.height;
    final zones = <String>{};
    final zoneList = doc?['zones'];
    if (zoneList is List<Object?>) {
      // A zone is sent back on the wire as is, so one this app would have
      // to rewrite to show is dropped, never altered.
      for (final z in zoneList) {
        if (zones.length == maxZones) break;
        if (z is String && _isZone(z)) zones.add(z);
      }
    }
    final blocked = <(int, int)>{};
    final cells = doc?['blocked'];
    if (cells is List<Object?>) {
      for (final cell in cells) {
        if (cell is List<Object?> &&
            cell.length == 2 &&
            cell[0] is int &&
            cell[1] is int) {
          final (x, y) = (cell[0]! as int, cell[1]! as int);
          // In-bounds only, so the set never exceeds width × height.
          if (x >= 0 && x < width && y >= 0 && y < height) blocked.add((x, y));
        }
      }
    }
    return MapLayout(
      name: name is String && _isLabel(name, maxNameRunes)
          ? name
          : fallback.name,
      width: width,
      height: height,
      zones: zones.toList(growable: false),
      blocked: blocked,
    );
  }

  /// What the map looks like before the asset arrives, or when it has none.
  static const MapLayout fallback = MapLayout(
    name: 'unnamed',
    width: 20,
    height: 20,
    zones: <String>[],
    blocked: <(int, int)>{},
  );

  /// A side longer than this is refused and falls back; the painter draws
  /// every cell.
  static const int maxSide = 64;

  /// Zones beyond this many are ignored.
  static const int maxZones = 16;

  /// The gateway's zone cap, in UTF-8 bytes; a longer zone would be refused.
  static const int maxZoneBytes = 64;

  /// A longer map name falls back.
  static const int maxNameRunes = 32;

  final String name;
  final int width;
  final int height;

  /// Distinct, in document order, each one a zone the gateway accepts.
  final List<String> zones;
  final Set<(int, int)> blocked;

  bool isBlocked(double x, double y) =>
      blocked.contains((x.round(), y.round()));

  /// For the log panel: shape only, never the document's own strings.
  String get summary =>
      '${width}x$height, ${zones.length} zone(s), ${blocked.length} blocked';

  static int? _side(Object? v) => v is int && v >= 1 && v <= maxSide ? v : null;

  static bool _isZone(String z) =>
      utf8.encode(z).length <= maxZoneBytes && _isLabel(z, maxZoneBytes);

  /// Whether [s] may be shown as a label: the check the map applies to a
  /// zone and a name, for any other text off the wire (a player's display
  /// name, say). The reference list of rules/security.md, "Trusting the
  /// wire".
  static bool isLabel(String s, int maxRunes) => _isLabel(s, maxRunes);

  /// Non-empty, at most [maxRunes] characters, and nothing that could
  /// rearrange, hide or split what the UI shows, or make two zones differ
  /// only invisibly: no control or format characters (directional marks and
  /// overrides, zero-width and invisible characters, tags), no line or
  /// paragraph separators, no lone surrogates.
  static bool _isLabel(String s, int maxRunes) {
    if (s.isEmpty || s.runes.length > maxRunes) return false;
    for (final r in s.runes) {
      if (r < 0x20 ||
          (r >= 0x7f && r < 0xa0) ||
          r == 0xad ||
          r == 0x61c ||
          r == 0x180e ||
          (r >= 0x200b && r <= 0x200f) ||
          (r >= 0x2028 && r <= 0x202e) ||
          (r >= 0x2060 && r <= 0x206f) ||
          (r >= 0xd800 && r <= 0xdfff) ||
          r == 0xfeff ||
          (r >= 0xfff9 && r <= 0xfffb) ||
          (r >= 0xe0000 && r <= 0xe007f) ||
          _isInvisible(r)) {
        return false;
      }
    }
    return true;
  }

  /// The rest of Unicode's format characters and the blanks that render as
  /// nothing: variation selectors, Hangul fillers, the grapheme joiner, the
  /// blank Braille cell, and prefixed-number and control formats.
  static bool _isInvisible(int r) =>
      r == 0x34f ||
      (r >= 0x600 && r <= 0x605) ||
      r == 0x6dd ||
      r == 0x70f ||
      r == 0x8e2 ||
      r == 0x115f ||
      r == 0x1160 ||
      r == 0x2800 ||
      r == 0x3164 ||
      (r >= 0xfe00 && r <= 0xfe0f) ||
      r == 0xffa0 ||
      r == 0x110bd ||
      r == 0x110cd ||
      (r >= 0x13430 && r <= 0x1343f) ||
      (r >= 0x1bca0 && r <= 0x1bca3) ||
      (r >= 0x1d173 && r <= 0x1d17a) ||
      (r >= 0xe0100 && r <= 0xe01ef);
}
