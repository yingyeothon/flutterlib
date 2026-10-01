import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// The one exception the client throws for anything the server, or the
/// network, refused. Local refusals (grammar, bounds) are plain
/// [ArgumentError]s thrown before any request is made.
///
/// Carries a status and a code, never an owner, a `meta`, a URL or the
/// token.
final class LeaderboardException implements Exception {
  /// Creates an exception.
  const LeaderboardException(this.status, this.code, {this.reason});

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

  /// `error.details.reason` when the server named one: `board_full` on a
  /// `409`.
  final String? reason;

  /// `404`: no such board in the caller's project (a board of another
  /// project is the same answer, on purpose), or no score for that owner.
  bool get isNotFound => status == 404;

  /// `403`: a player on a `submit: server` board, another player's row, or
  /// a delete without the server key.
  bool get isForbidden => status == 403;

  /// `401`: the token is missing, expired or not for this stage.
  bool get isUnauthorized => status == 401;

  /// `409`: a bucket at its cap refused the whole submission.
  bool get isBoardFull => status == 409 && reason == 'board_full';

  /// `400`: a period the board does not keep, `me` from a server key, a
  /// score or `meta` the server refused for a reason the local checks could
  /// not know (a `meta` over the cap is a `413` there, refused here first).
  bool get isBadRequest => status == 400;

  /// Builds the exception from a refused response. The body is read for its
  /// `code` and `details.reason` only.
  factory LeaderboardException.fromResponse(int status, String body) {
    final decoded = Json.tryDecode(body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    final error = value is JsonObject ? value.getObject('error') : null;
    final details = error?.getObject('details');
    // `code` and `reason` reach `toString()` and log lines, so a value the
    // server (or whatever answered in its place) chose outside the code
    // grammar is dropped rather than carried.
    final code = error?.getString('code');
    final reason = details?.getString('reason');
    return LeaderboardException(
      status,
      code != null && _codePattern.hasMatch(code) ? code : 'http_$status',
      reason: reason != null && _codePattern.hasMatch(reason) ? reason : null,
    );
  }

  static final RegExp _codePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  /// Deliberately the code and the status only.
  @override
  String toString() => 'LeaderboardException($code, $status)';
}
