import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'internal/client_impl.dart';
import 'types.dart';

/// Options for a [SocialClient]. Immutable; a new token is a new client.
final class SocialClientOptions {
  /// Creates options.
  const SocialClientOptions({
    required this.baseUrl,
    required this.token,
    this.client,
    this.logger,
    this.timeout,
  });

  /// `https://doc.yyt.life` or `https://doc-dev.yyt.life`, the state stack
  /// that also serves the key-value store; no default. A path is kept and
  /// the `/social/…` routes are appended to it.
  final Uri baseUrl;

  /// The channel JWT (a player) or the auth channel's doc apiKey (the game's
  /// server). Sent as `Authorization: Bearer` and never logged.
  final String token;

  /// The HTTP client to send with; `null` creates one the library owns and
  /// [SocialClient.close] closes. An injected client is never closed here.
  final http.Client? client;

  /// Receives `social request` lines with the method, the route kind, the
  /// status and the body length; `null` is [nullLogger].
  final Logger? logger;

  /// One deadline for headers and body; `null` is 15 seconds.
  final Duration? timeout;
}

/// A client for yyt social, speaking for one credential. The `me` methods
/// are a player's (a server key gets `403`); [server] is the key's.
abstract interface class SocialClient {
  /// Creates a client. Throws [ArgumentError] when
  /// [SocialClientOptions.baseUrl] is not a bare absolute `http(s)` URL (no
  /// user info, query or fragment) or the token is empty or has a character
  /// outside printable ASCII; the message names an index, never the
  /// character.
  factory SocialClient(SocialClientOptions options) = SocialClientImpl;

  /// `GET /social/me/profile`: my card, or `null` when I have none (a
  /// `404`).
  Future<SocialProfile?> myProfile();

  /// `PUT /social/me/profile`: my card, whole — an absent [avatar] clears
  /// it. Throws [ArgumentError] for a [displayName] outside 1 … 32
  /// characters or carrying a control, format or line-separator character
  /// or a run of combining marks, or an [avatar] that is not a short id or
  /// path. A card admits a player to the graph: every relation needs one at
  /// both ends.
  Future<SocialProfileResult> putMyProfile(
    String displayName, {
    String? avatar,
  });

  /// `DELETE /social/me/profile`: my card and my relations in both
  /// directions (not somebody else's block of me). Returns `false` when I
  /// had none (a `404`).
  Future<bool> deleteMyProfile();

  /// `GET /social/profiles?ids=`: the cards of up to 50 owners; an owner
  /// nobody claimed is simply absent, a blocker's card is not hidden. Open
  /// to every credential of the channel. Throws [ArgumentError] for no id,
  /// more than 50, or one outside the owner grammar.
  Future<List<SocialProfile>> profiles(Iterable<String> ids);

  /// `GET /social/friends`: my friends with their cards, in the order the
  /// server lists them (sort by [SocialRelation.since] yourself).
  Future<List<SocialRelation>> friends();

  /// `GET /social/requests`: what waits for me and what I sent.
  Future<SocialRequests> requests();

  /// `GET /social/blocks`: whom I blocked, so a spent cap can be cleared.
  Future<List<SocialRelation>> blocks();

  /// `POST /social/requests` with `{to}`: ask [player] to be friends. When
  /// they had already asked me, the two settle into a friendship at once
  /// ([SocialRequestResult.state]). Throws [ArgumentError] for an id that is
  /// not 32 hex; [SocialException] for a `404` (no card, blocked me, or no
  /// such player — one answer), a `409` (`profile_required`, `blocked`, a
  /// full list on either side) or a `400` (myself).
  Future<SocialRequestResult> request(String player);

  /// `POST /social/requests/{player}/accept`: `204`, or a `404` when no
  /// request from [player] waits.
  Future<void> accept(String player);

  /// `POST /social/requests/{player}/decline`: `204`. Silent to the sender,
  /// whose slot stays spent for 30 days.
  Future<void> decline(String player);

  /// `DELETE /social/requests/{player}`: withdraw my own request; a declined
  /// one is refused (`404`), since withdrawing it would clear the cooldown.
  Future<void> withdraw(String player);

  /// `DELETE /social/friends/{player}`: both rows, `204`.
  Future<void> unfriend(String player);

  /// `PUT /social/blocks/{player}`: block, idempotent; drops their request
  /// or our friendship, never their block of me. May name any player id,
  /// card or not. Throws [SocialException] `400` for myself, `409`
  /// `blocks_full`.
  Future<void> block(String player);

  /// `DELETE /social/blocks/{player}`: unblock; a cooldown the block
  /// preserved comes back, a friendship does not.
  Future<void> unblock(String player);

  /// The doc apiKey's routes; a player's token gets `403` on each.
  SocialServerCommands get server;

  /// Closes the HTTP client this library created; an injected one is left
  /// to its owner. Idempotent. A request after `close()` on an owned client
  /// fails as a [SocialException] with [SocialException.networkCode].
  void close();
}

/// What the auth channel's doc apiKey may do: read anyone's friends, write
/// and delete cards, delete relations — never create one.
abstract interface class SocialServerCommands {
  /// `GET /social/u/{player}/friends`.
  Future<List<SocialRelation>> friendsOf(String player);

  /// `PUT /social/u/{owner}/profile`: a card for [owner], who may be a guild
  /// (`kind:id`), not only a player.
  Future<SocialProfileResult> putProfile(
    String owner,
    String displayName, {
    String? avatar,
  });

  /// `DELETE /social/u/{owner}/profile`. Returns `false` on a `404`.
  Future<bool> deleteProfile(String owner);

  /// `DELETE /social/u/{player}/relations[/{other}]`: every relation of
  /// [player], or only the pair with [other]; the moderation tool. Returns
  /// how many rows went.
  Future<int> deleteRelations(String player, {String? other});
}
