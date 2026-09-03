/// Frame type names, in one place. Mirrors `protocol.go` in the gateway.
abstract final class FrameTypes {
  /// First frame on a lobby channel.
  static const String hello = 'hello';

  /// The whole view, on zone entry and on resync.
  static const String snapshot = 'snapshot';

  /// A peer came into view.
  static const String enter = 'enter';

  /// A peer left the view.
  static const String leave = 'leave';

  /// Client: announce a position. Gateway: one coalesced batch per tick.
  static const String pos = 'pos';

  /// Chat.
  static const String say = 'say';

  /// Opaque game event.
  static const String event = 'event';

  /// Roster snapshot.
  static const String party = 'party';

  /// Client: create a party.
  static const String partyCreate = 'party.create';

  /// Client: invite; gateway: you were invited.
  static const String partyInvite = 'party.invite';

  /// Client: accept an invite.
  static const String partyAccept = 'party.accept';

  /// Client: decline an invite.
  static const String partyDecline = 'party.decline';

  /// Gateway: an invite was declined (to the leader).
  static const String partyDeclined = 'party.declined';

  /// Client: leave the party.
  static const String partyLeave = 'party.leave';

  /// Client: ask for the roster.
  static const String partyList = 'party.list';

  /// Application-level ping.
  static const String ping = 'ping';

  /// Answer to [ping].
  static const String pong = 'pong';

  /// A refusal: `{type, code, message}`.
  static const String error = 'error';
}

/// Types the gateway synthesises itself on a `q` channel and refuses from a
/// client with `reserved_type`. The SDK refuses them locally too.
const List<String> reservedGameFrameTypes = <String>['enter', 'leave'];

/// Documented refusal codes. String constants, not an enum: the set is open
/// and a future code must not turn into a parse failure.
abstract final class GatewayErrorCode {
  /// Not a JSON object with a string `type`, or a field of the wrong type.
  static const String badMessage = 'bad_message';

  /// The channel does not enable that feature.
  static const String capabilityOff = 'capability_off';

  /// Over the per-connection token bucket.
  static const String rateLimited = 'rate_limited';

  /// `scope` is not one the channel allows.
  static const String badScope = 'bad_scope';

  /// Bad or missing `zone`.
  static const String badZone = 'bad_zone';

  /// A `pos` jumped further than `maxMoveDelta` within a zone.
  static const String moveTooFar = 'move_too_far';

  /// `to` names nobody online.
  static const String unknownUser = 'unknown_user';

  /// A party operation without a party.
  static const String noParty = 'no_party';

  /// Already a member of a party.
  static const String alreadyInParty = 'already_in_party';

  /// The party is at `partySizeMax`.
  static const String partyFull = 'party_full';

  /// Accepting or declining an invite that was never sent.
  static const String notInvited = 'not_invited';

  /// No such party.
  static const String unknownParty = 'unknown_party';

  /// Only the leader may do that.
  static const String notLeader = 'not_leader';

  /// A field over its byte limit.
  static const String tooLong = 'too_long';

  /// `q`: a client tried to send `enter` or `leave`.
  static const String reservedType = 'reserved_type';

  /// `q`: the push to the actor's queue failed.
  static const String unavailable = 'unavailable';

  /// A frame meant for you exceeded the outbound cap and was dropped.
  static const String frameTooLarge = 'frame_too_large';
}

/// Routing scope of a `say` or `event`.
enum SayScope {
  /// Everyone whose view has you.
  zone,

  /// Your party.
  party,

  /// One user, named by `to`.
  user;

  /// The wire form.
  String get wire => name;

  /// Parses the wire form; `null` for anything else.
  static SayScope? tryParse(String? value) => switch (value) {
    'zone' => SayScope.zone,
    'party' => SayScope.party,
    'user' => SayScope.user,
    _ => null,
  };
}
