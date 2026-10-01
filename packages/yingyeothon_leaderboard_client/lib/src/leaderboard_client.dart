import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'internal/client_impl.dart';
import 'rules.dart';
import 'types.dart';

/// Options for a [LeaderboardClient]. Immutable; a new token is a new client.
final class LeaderboardClientOptions {
  /// Creates options.
  const LeaderboardClientOptions({
    required this.baseUrl,
    required this.token,
    this.client,
    this.logger,
    this.timeout,
  });

  /// `https://doc.yyt.life` or `https://doc-dev.yyt.life`, the state stack
  /// that also serves the key-value store; no default. A path is kept and
  /// the `/lb/…` routes are appended to it.
  final Uri baseUrl;

  /// The channel JWT (a player) or the auth channel's doc apiKey (the game's
  /// server). Sent as `Authorization: Bearer` and never logged.
  final String token;

  /// The HTTP client to send with; `null` creates one the library owns and
  /// [LeaderboardClient.close] closes. An injected client is never closed
  /// here.
  final http.Client? client;

  /// Receives `lb request` lines with the method, the route kind, the status
  /// and the body length; `null` is [nullLogger].
  final Logger? logger;

  /// One deadline for headers and body; `null` is 15 seconds.
  final Duration? timeout;
}

/// A client for yyt leaderboards, speaking for one credential.
abstract interface class LeaderboardClient {
  /// Creates a client. Throws [ArgumentError] when
  /// [LeaderboardClientOptions.baseUrl] is not a bare absolute `http(s)` URL
  /// (no user info, query or fragment) or the token is empty or has a
  /// character outside printable ASCII; the message names an index, never
  /// the character.
  factory LeaderboardClient(LeaderboardClientOptions options) =
      LeaderboardClientImpl;

  /// Addresses a board by its `lb_` id or by its console name, resolved by
  /// the server within the caller's project. Pure: it builds paths and holds
  /// no state. Throws [ArgumentError] for a segment outside both grammars.
  Leaderboard board(String nameOrId);

  /// Closes the HTTP client this library created; an injected one is left
  /// to its owner. Idempotent. A request after `close()` on an owned client
  /// fails as a [LeaderboardException] with
  /// [LeaderboardException.networkCode].
  void close();
}

/// One board: its shape, its scores and its ranked pages.
abstract interface class Leaderboard {
  /// What was passed to [LeaderboardClient.board].
  String get ref;

  /// `GET /lb/{board}`: the shape and the live bucket of every period. Open
  /// to every credential of the project.
  Future<LeaderboardInfo> info();

  /// `PUT /lb/{board}/scores/{owner}` with `{score, meta?}`: one write to
  /// every bucket the board keeps, judged by its rule. [owner] is `me` (a
  /// player's own row, on a `submit: owner` board) or an id the server key
  /// names: 32 hex, or `kind:id` for a guild. [meta] is JSON text stored
  /// byte for byte, at most 1 KiB, no control characters; absent clears the
  /// stored one when the score is accepted. Throws [ArgumentError] for a
  /// score outside the safe-integer range or a `meta` the server would
  /// refuse (over the cap it would be a `413`); [LeaderboardException] for a
  /// `403` (not yours to write), a `409` `board_full` (a bucket at its cap
  /// refuses the whole write), a `404` (no such board in your project) or a
  /// `400` (`me` from a server key).
  Future<LbSubmitResult> submit(
    int score, {
    String owner = LbRules.selfOwner,
    String? meta,
  });

  /// `GET /lb/{board}/top`: one bucket's ranked page. [period] names a
  /// period the board keeps (`null` is its first); [limit] 1 … 100 (the
  /// server default is 20); [offset] 0 … 1000. Throws [ArgumentError] for
  /// values outside those bounds.
  Future<LbPage> top({String? period, int? limit, int? offset});

  /// `GET /lb/{board}/scores/{owner}`: one owner's row with its rank in the
  /// bucket of [period] (`null` is the board's first), or `null` on a
  /// `404` — that owner has no row there, **or there is no such board in
  /// your project**: the two share one answer, and [info] is what tells
  /// them apart. [owner] is `me` or an id.
  Future<LbScore?> score({String owner = LbRules.selfOwner, String? period});

  /// `DELETE /lb/{board}/scores/{owner}`: the owner's row in every bucket.
  /// Server key only (`403` for a player). Returns `false` on a `404`:
  /// nothing to delete, or no such board in your project ([info] tells).
  Future<bool> deleteScore(String owner);

  /// `DELETE /lb/{board}/periods/{period}`: one batch of the current bucket
  /// of [period]; call again while [LbClearResult.truncated]. Server key
  /// only.
  Future<LbClearResult> clearPeriod(String period);
}
