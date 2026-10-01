import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// The one exception the client throws for anything the server, or the
/// network, refused. Local refusals (grammar, bounds) are plain
/// [ArgumentError]s thrown before any request is made.
///
/// Carries a status and a code, never a player id, a display name, a URL or
/// the token.
final class SocialException implements Exception {
  /// Creates an exception.
  const SocialException(this.status, this.code, {this.reason});

  /// The request never got an answer: timeout or network error.
  static const String networkCode = 'network';

  /// The server promised JSON and sent something else, or a body over the
  /// 1 MiB cap; [status] is the answer's.
  static const String malformedResponseCode = 'malformed_response';

  /// HTTP status; `0` when the request never got an answer.
  final int status;

  /// The server's `error.code` when it matches `^[a-z][a-z0-9_]{0,63}$`, or
  /// `http_<status>` when the body carried none (or one outside that
  /// grammar), or [networkCode] / [malformedResponseCode].
  final String code;

  /// `error.details.reason` when the server named one: `not_found`,
  /// `profile_required`, `blocked`, `friends_full`, `peer_friends_full`,
  /// `pending_full`, `peer_pending_full`, `blocks_full`, `channel_full`.
  final String? reason;

  /// `404`: no card, or on a relation write the target has no card, blocked
  /// you, or does not exist — one answer for all three, on purpose.
  bool get isNotFound => status == 404;

  /// `403`: a server key on a `me` route, a player on a server route, or a
  /// token whose subject is not a player id.
  bool get isForbidden => status == 403;

  /// `401`: the token is missing, expired or not for this stage.
  bool get isUnauthorized => status == 401;

  /// `409`: a cap or a precondition; [reason] says which.
  bool get isConflict => status == 409;

  /// `409` `profile_required`: set your card before making a relation.
  bool get isProfileRequired => isConflict && reason == 'profile_required';

  /// `409` `blocked`: you blocked that player; unblock first.
  bool get isBlocked => isConflict && reason == 'blocked';

  /// `409` with a `_full` reason: your or their friend list, a pending cap
  /// in either direction, your block list, or the channel's profiles.
  bool get isFull => isConflict && (reason?.endsWith('_full') ?? false);

  /// `400`: a self-relation, or a body the local checks could not know the
  /// server would refuse.
  bool get isBadRequest => status == 400;

  /// Builds the exception from a refused response. The body is read for its
  /// `code` and `details.reason` only.
  factory SocialException.fromResponse(int status, String body) {
    final decoded = Json.tryDecode(body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    final error = value is JsonObject ? value.getObject('error') : null;
    final details = error?.getObject('details');
    // `code` and `reason` reach `toString()` and log lines, so a value the
    // server (or whatever answered in its place) chose outside the code
    // grammar is dropped rather than carried.
    final code = error?.getString('code');
    final reason = details?.getString('reason');
    return SocialException(
      status,
      code != null && _codePattern.hasMatch(code) ? code : 'http_$status',
      reason: reason != null && _codePattern.hasMatch(reason) ? reason : null,
    );
  }

  static final RegExp _codePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  /// Deliberately the code and the status only.
  @override
  String toString() => 'SocialException($code, $status)';
}
