import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import 'frame_types.dart';

/// The channel's capability object, forwarded verbatim in `hello`.
///
/// A `null` field means the gateway did not say, and the SDK treats that as
/// allowed: the local checks are a courtesy that gives a fast error, and the
/// gateway is the enforcement. Only an explicit `false` (or a `say` list
/// that omits the scope) refuses locally.
final class Capabilities {
  /// Creates a capability set.
  const Capabilities({this.pos, this.say, this.party, this.event, this.debug});

  /// Reads the `capabilities` object of a `hello`.
  factory Capabilities.fromJson(JsonObject? json) {
    if (json == null) return const Capabilities();
    final sayRaw = json['say'];
    return Capabilities(
      pos: json.getBool('pos'),
      say: sayRaw is List<Object?>
          ? sayRaw.whereType<String>().toList(growable: false)
          : null,
      party: json.getBool('party'),
      event: json.getBool('event'),
      debug: json.getBool('debug'),
    );
  }

  /// Whether `pos` frames are accepted.
  final bool? pos;

  /// The `say` scopes accepted; `null` when unrestricted, `[]` when none.
  final List<String>? say;

  /// Whether `party.*` frames are accepted.
  final bool? party;

  /// Whether `event` frames are accepted.
  final bool? event;

  /// Whether the channel is in debug mode.
  final bool? debug;

  /// Whether a `say`/`event` with [scope] passes the local check.
  bool allowsScope(SayScope scope) {
    final list = say;
    return list == null || list.contains(scope.wire);
  }
}
