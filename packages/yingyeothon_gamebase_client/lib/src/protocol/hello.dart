import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import 'capabilities.dart';
import 'normalize.dart';

/// The channel's view rule, from `hello.aoi`: `maxPeers` always, `range`
/// only when the channel filters by a box around your last `pos`.
final class Aoi {
  /// Creates a view rule.
  const Aoi({required this.maxPeers, this.range});

  /// Reads the `aoi` object; `null` when absent or not an object.
  static Aoi? fromJson(JsonObject? json) {
    if (json == null) return null;
    return Aoi(
      maxPeers: json.getInt('maxPeers') ?? 0,
      range: json.getDouble('range'),
    );
  }

  /// At most this many nearest peers are in view.
  final int maxPeers;

  /// Chebyshev range of the box, or `null` when the channel has no box.
  final double? range;
}

/// First frame on a lobby channel; nothing is "connected" before it.
final class Hello {
  /// Creates a hello.
  const Hello({
    required this.userId,
    required this.connectionId,
    required this.tick,
    required this.mapUrl,
    required this.zone,
    required this.capabilities,
    required this.raw,
    this.partyId,
    this.aoi,
  });

  /// Reads a `hello` frame. Missing fields read as empty so a future
  /// gateway cannot fail the connect; the fields a client renders from are
  /// all present today.
  factory Hello.fromJson(JsonObject json) => Hello(
    userId: json.getString('userId') ?? '',
    connectionId: json.getString('connectionId') ?? '',
    tick: json.getInt('tick') ?? 0,
    mapUrl: json.getString('mapUrl') ?? '',
    zone: json.getString('zone') ?? '',
    partyId: Normalize.optionalId(json.getString('partyId')),
    capabilities: Capabilities.fromJson(json.getObject('capabilities')),
    aoi: Aoi.fromJson(json.getObject('aoi')),
    raw: json,
  );

  /// Your identity; the token's `sub`.
  final String userId;

  /// This socket's id on the gateway.
  final String connectionId;

  /// Position flush interval in milliseconds.
  final int tick;

  /// Immutable, public map asset. A new map version is a new URL.
  final String mapUrl;

  /// The zone the game should start in; you have no zone until the first
  /// `pos`.
  final String zone;

  /// Present when the gateway already knows your party.
  final String? partyId;

  /// What this channel enables.
  final Capabilities capabilities;

  /// The view rule, when the gateway sent one.
  final Aoi? aoi;

  /// The frame as received, for fields this SDK does not model.
  final JsonObject raw;
}
