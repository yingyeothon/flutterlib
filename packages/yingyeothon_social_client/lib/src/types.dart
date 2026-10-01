import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// The states a relation row can be in, as `request()` reports them. An
/// open string set, not an enum, so a state the service adds later cannot
/// become a parse failure.
abstract final class SocialRelationState {
  /// A live request in the other player's inbox.
  static const String requested = 'requested';

  /// Half of a friendship; the other row is the mirror.
  static const String friends = 'friends';
}

/// A player's card: a display name and an optional avatar id.
final class SocialProfile {
  /// Creates a profile.
  const SocialProfile({
    required this.owner,
    required this.displayName,
    required this.updatedAt,
    this.avatar,
    required this.raw,
  });

  /// Reads the object. A missing string reads as empty, a missing number as
  /// `0`, a missing avatar as `null`.
  factory SocialProfile.fromJson(JsonObject json) => SocialProfile(
    owner: json.getString('owner') ?? '',
    displayName: json.getString('displayName') ?? '',
    avatar: json.getString('avatar'),
    updatedAt: json.getInt('updatedAt') ?? 0,
    raw: json,
  );

  /// The owner's id: a player, or a guild a server named.
  final String owner;

  /// 1 … 32 characters, not unique: render the owner id beside it wherever a
  /// mistake matters.
  final String displayName;

  /// An id or a path into the game's own asset table, never a URL; `null`
  /// when none.
  final String? avatar;

  /// Epoch second of the last change.
  final int updatedAt;

  /// The object as received.
  final JsonObject raw;
}

/// What a profile write learned.
final class SocialProfileResult {
  /// Creates a result.
  const SocialProfileResult({required this.profile, required this.created});

  /// The stored card.
  final SocialProfile profile;

  /// Whether the card was created (`201`) rather than edited (`200`).
  final bool created;
}

/// One row of a friends, requests or blocks list: the other player with its
/// card folded in.
final class SocialRelation {
  /// Creates a relation.
  const SocialRelation({
    required this.owner,
    required this.since,
    this.displayName,
    this.avatar,
    required this.raw,
  });

  /// Reads the object.
  factory SocialRelation.fromJson(JsonObject json) => SocialRelation(
    owner: json.getString('owner') ?? '',
    displayName: json.getString('displayName'),
    avatar: json.getString('avatar'),
    since: json.getInt('since') ?? 0,
    raw: json,
  );

  /// The other player's id.
  final String owner;

  /// Their display name, or `null` when they hold no card (a block may name
  /// anyone).
  final String? displayName;

  /// Their avatar, or `null`.
  final String? avatar;

  /// Epoch second the relation was made: what a friends list sorts by.
  final int since;

  /// The row as received.
  final JsonObject raw;
}

/// The two halves of `GET /social/requests`.
final class SocialRequests {
  /// Creates the pair.
  const SocialRequests({required this.incoming, required this.outgoing});

  /// Requests waiting for this player's accept or decline.
  final List<SocialRelation> incoming;

  /// Requests this player sent and may withdraw. A declined one is shown
  /// here exactly like a pending one; the decline is silent.
  final List<SocialRelation> outgoing;
}

/// What `request()` learned.
final class SocialRequestResult {
  /// Creates a result.
  const SocialRequestResult({required this.state, required this.created});

  /// [SocialRelationState.requested], or [SocialRelationState.friends] when
  /// the other player had already asked and the two requests settled.
  final String state;

  /// Whether a new pending request was written (`201`); `false` (`200`) when
  /// one was already pending, the two were already friends, or they had
  /// asked first and the two settled at once ([state] says which).
  final bool created;
}
