import 'dart:convert';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import 'frame_types.dart';

/// The gateway refuses a `dir` longer than this many **bytes** as
/// `bad_message`.
const int maxDirBytes = 16;

/// Whether [dir] exceeds [maxDirBytes] in UTF-8.
bool isDirTooLong(String dir) => utf8.encode(dir).length > maxDirBytes;

/// Builds every client → gateway lobby frame. The one place a lobby frame is
/// assembled, so escaping and field omission are decided once.
abstract final class LobbyFrameWriter {
  /// `pos`; [dir] is omitted when `null`.
  static JsonObject pos(String zone, double x, double y, String? dir) =>
      Json.object()
          .set('type', FrameTypes.pos)
          .set('zone', zone)
          .set('x', x)
          .set('y', y)
          .set('dir', dir)
          .build();

  /// `say`; [to] is omitted when `null`.
  static JsonObject say(SayScope scope, String text, String? to) =>
      Json.object()
          .set('type', FrameTypes.say)
          .set('scope', scope.wire)
          .set('to', to)
          .set('text', text)
          .build();

  /// `event`; [to] and a `null` [payload] are omitted.
  static JsonObject event(
    SayScope scope,
    String name,
    Object? payload,
    String? to,
  ) => Json.object()
      .set('type', FrameTypes.event)
      .set('scope', scope.wire)
      .set('to', to)
      .set('name', name)
      .set('payload', payload)
      .build();

  /// `party.create`.
  static JsonObject partyCreate() =>
      Json.object().set('type', FrameTypes.partyCreate).build();

  /// `party.invite`.
  static JsonObject partyInvite(String userId) => Json.object()
      .set('type', FrameTypes.partyInvite)
      .set('userId', userId)
      .build();

  /// `party.accept`.
  static JsonObject partyAccept(String partyId) => Json.object()
      .set('type', FrameTypes.partyAccept)
      .set('partyId', partyId)
      .build();

  /// `party.decline`.
  static JsonObject partyDecline(String partyId) => Json.object()
      .set('type', FrameTypes.partyDecline)
      .set('partyId', partyId)
      .build();

  /// `party.leave`.
  static JsonObject partyLeave() =>
      Json.object().set('type', FrameTypes.partyLeave).build();

  /// `party.list`.
  static JsonObject partyList() =>
      Json.object().set('type', FrameTypes.partyList).build();

  /// `ping`.
  static JsonObject ping() =>
      Json.object().set('type', FrameTypes.ping).build();
}
