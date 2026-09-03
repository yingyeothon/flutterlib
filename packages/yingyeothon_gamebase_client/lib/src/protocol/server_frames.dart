import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import 'frame_types.dart';
import 'normalize.dart';
import 'peer.dart';

/// A parsed gateway → client lobby frame. Every subtype keeps [raw].
sealed class LobbyServerFrame {
  const LobbyServerFrame(this.raw);

  /// The frame as received.
  final JsonObject raw;

  /// The wire `type`.
  String get type => raw.getString('type') ?? '';
}

/// `snapshot`: replace the peer map with [peers] for [zone].
final class SnapshotFrame extends LobbyServerFrame {
  /// Creates a snapshot frame.
  const SnapshotFrame(super.raw, {required this.zone, required this.peers});

  /// The zone you just entered.
  final String zone;

  /// Everyone in view.
  final List<Peer> peers;
}

/// `enter`: [peer] came into your view in [zone].
final class EnterFrame extends LobbyServerFrame {
  /// Creates an enter frame.
  const EnterFrame(super.raw, {required this.zone, required this.peer});

  /// The zone.
  final String zone;

  /// The peer and its position.
  final Peer peer;
}

/// `leave`: [userId] left your view in [zone].
final class LeaveFrame extends LobbyServerFrame {
  /// Creates a leave frame.
  const LeaveFrame(super.raw, {required this.zone, required this.userId});

  /// The zone.
  final String zone;

  /// Who left.
  final String userId;
}

/// `pos`: one coalesced batch per tick of peers in view that moved. Includes
/// your own entry; [PeerMap] drops it.
final class PosBroadcastFrame extends LobbyServerFrame {
  /// Creates a pos batch.
  const PosBroadcastFrame(super.raw, {required this.zone, required this.peers});

  /// The zone.
  final String zone;

  /// Who moved, with their new positions.
  final List<Peer> peers;
}

/// `say`: chat mirrored to its scope, sender included.
final class SayBroadcastFrame extends LobbyServerFrame {
  /// Creates a say frame.
  const SayBroadcastFrame(
    super.raw, {
    required this.from,
    required this.scope,
    required this.text,
    this.to,
  });

  /// Who said it.
  final String from;

  /// The scope as sent; a scope this SDK does not know parses to `null`
  /// in [sayScope] but is still delivered.
  final String scope;

  /// The target user of a whisper.
  final String? to;

  /// The text.
  final String text;

  /// [scope] parsed.
  SayScope? get sayScope => SayScope.tryParse(scope);
}

/// `event`: an opaque game event mirrored to its scope, sender included.
final class EventBroadcastFrame extends LobbyServerFrame {
  /// Creates an event frame.
  const EventBroadcastFrame(
    super.raw, {
    required this.from,
    required this.scope,
    required this.name,
    this.payload,
    this.to,
  });

  /// Who sent it.
  final String from;

  /// The scope as sent.
  final String scope;

  /// The target user of a whisper.
  final String? to;

  /// The game's event name.
  final String name;

  /// The game's payload, unread by the gateway; `null` when absent.
  final Object? payload;

  /// [scope] parsed.
  SayScope? get sayScope => SayScope.tryParse(scope);
}

/// One roster entry.
final class PartyMember {
  /// Creates a member.
  const PartyMember({required this.userId, required this.online});

  /// Who.
  final String userId;

  /// Whether their lobby socket is up right now.
  final bool online;

  @override
  bool operator ==(Object other) =>
      other is PartyMember && other.userId == userId && other.online == online;

  @override
  int get hashCode => Object.hash(userId, online);
}

/// `party`: the roster on every change and on reconnect.
///
/// The gateway marshals with Go `omitempty`: `leaderId`, `invited` and `max`
/// are missing when empty, and `partyId: ""` means "no party". This type
/// fills them in — [partyId] is `null` for no party, the lists are empty,
/// [max] is `0` — so a handler reads `roster.invited.length` without a guard.
final class PartyFrame extends LobbyServerFrame {
  /// Creates a roster frame.
  const PartyFrame(
    super.raw, {
    required this.partyId,
    required this.leaderId,
    required this.members,
    required this.invited,
    required this.max,
  });

  /// The party, or `null` when you are in none.
  final String? partyId;

  /// The leader; `""` when there is no party.
  final String leaderId;

  /// The members.
  final List<PartyMember> members;

  /// Users with a pending invite.
  final List<String> invited;

  /// The channel's party size cap; `0` when not sent.
  final int max;
}

/// `party.invite`: you were invited.
final class PartyInviteFrame extends LobbyServerFrame {
  /// Creates an invite frame.
  const PartyInviteFrame(
    super.raw, {
    required this.partyId,
    required this.from,
  });

  /// The party.
  final String partyId;

  /// The leader who invited you.
  final String from;
}

/// `party.declined`: (leader) an invite was refused.
final class PartyDeclinedFrame extends LobbyServerFrame {
  /// Creates a declined frame.
  const PartyDeclinedFrame(
    super.raw, {
    required this.partyId,
    required this.userId,
  });

  /// The party.
  final String partyId;

  /// Who declined.
  final String userId;
}

/// `pong`.
final class PongFrame extends LobbyServerFrame {
  /// Creates a pong frame.
  const PongFrame(super.raw);
}

/// `error`: a refusal. Log [code]; never [message], which may quote what
/// was sent.
final class ErrorFrame extends LobbyServerFrame {
  /// Creates an error frame.
  const ErrorFrame(super.raw, {required this.code, required this.message});

  /// A [GatewayErrorCode] value, or a future one.
  final String code;

  /// Human-readable detail.
  final String message;
}

/// A frame whose `type` this SDK does not know. Delivered on `frames` and
/// reported as a protocol error; never dropped silently.
final class UnknownServerFrame extends LobbyServerFrame {
  /// Creates an unknown frame.
  const UnknownServerFrame(super.raw);
}

List<Peer> _peers(JsonObject json) => json
    .getListOrEmpty('peers')
    .map(Peer.fromJson)
    .whereType<Peer>()
    .toList(growable: false);

/// Parses one lobby frame. [json] must already have a string `type`.
LobbyServerFrame readLobbyFrame(JsonObject json) {
  final zone = json.getString('zone') ?? '';
  switch (json.getString('type')) {
    case FrameTypes.snapshot:
      return SnapshotFrame(json, zone: zone, peers: _peers(json));
    case FrameTypes.enter:
      return EnterFrame(
        json,
        zone: zone,
        peer: Peer.fromJson(json) ?? const Peer(userId: '', x: 0, y: 0),
      );
    case FrameTypes.leave:
      return LeaveFrame(
        json,
        zone: zone,
        userId: json.getString('userId') ?? '',
      );
    case FrameTypes.pos:
      return PosBroadcastFrame(json, zone: zone, peers: _peers(json));
    case FrameTypes.say:
      return SayBroadcastFrame(
        json,
        from: json.getString('from') ?? '',
        scope: json.getString('scope') ?? '',
        to: Normalize.optionalId(json.getString('to')),
        text: json.getString('text') ?? '',
      );
    case FrameTypes.event:
      return EventBroadcastFrame(
        json,
        from: json.getString('from') ?? '',
        scope: json.getString('scope') ?? '',
        to: Normalize.optionalId(json.getString('to')),
        name: json.getString('name') ?? '',
        payload: json['payload'],
      );
    case FrameTypes.party:
      return PartyFrame(
        json,
        partyId: Normalize.optionalId(json.getString('partyId')),
        leaderId: json.getString('leaderId') ?? '',
        members: json
            .getListOrEmpty('members')
            .whereType<Map<String, Object?>>()
            .map(
              (m) => PartyMember(
                userId: m.getString('userId') ?? '',
                online: m.getBool('online') ?? false,
              ),
            )
            .toList(growable: false),
        invited: json
            .getListOrEmpty('invited')
            .whereType<String>()
            .toList(growable: false),
        max: json.getInt('max') ?? 0,
      );
    case FrameTypes.partyInvite:
      return PartyInviteFrame(
        json,
        partyId: json.getString('partyId') ?? '',
        from: json.getString('from') ?? '',
      );
    case FrameTypes.partyDeclined:
      return PartyDeclinedFrame(
        json,
        partyId: json.getString('partyId') ?? '',
        userId: json.getString('userId') ?? '',
      );
    case FrameTypes.pong:
      return PongFrame(json);
    case FrameTypes.error:
      return ErrorFrame(
        json,
        code: json.getString('code') ?? '',
        message: json.getString('message') ?? '',
      );
    default:
      return UnknownServerFrame(json);
  }
}
