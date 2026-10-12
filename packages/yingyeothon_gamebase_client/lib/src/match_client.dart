import 'package:http/http.dart' as http;
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'internal/match_client_impl.dart';
import 'transport/web_socket.dart';

/// One member of a live or confirmed deferred match.
final class MatchMember {
  /// Creates an immutable member, retaining service extension fields.
  MatchMember(this.userId, JsonObject raw) : raw = Map.unmodifiable(raw);

  /// The service-authenticated participant.
  final String userId;

  /// The member object as received, including unknown fields.
  final JsonObject raw;
}

/// Shared result of live matching and a confirmed deferred ticket.
final class MatchResult {
  /// Creates a result. Collections are copied.
  MatchResult({
    required this.matchId,
    required this.partial,
    required this.result,
    required List<MatchMember> members,
    required JsonObject raw,
  }) : members = List.unmodifiable(members),
       raw = Map.unmodifiable(raw);

  /// The match identifier.
  final String matchId;

  /// Whether fewer than the configured party size matched.
  final bool partial;

  /// The callback's opaque JSON result; null for callback-less channels.
  final Object? result;

  /// Participants in ticket order.
  final List<MatchMember> members;

  /// The result object including service extensions.
  final JsonObject raw;
}

/// A deferred ticket. Open state strings remain extensible.
final class MatchTicket {
  /// Creates a ticket retaining its complete wire object.
  MatchTicket({required this.state, required JsonObject raw, this.confirmed})
    : raw = Map.unmodifiable(raw);

  /// waiting, proposed, confirmed, expired, declined or failed.
  final String state;

  /// The original ticket object; never log it.
  final JsonObject raw;

  /// Only a confirmed ticket carries the shared result.
  final MatchResult? confirmed;

  /// Match identifier when present.
  String? get matchId => raw.getString('matchId');

  /// Proposal deadline in epoch seconds.
  int? get acceptBy => raw.getInt('acceptBy');

  /// Whether this player accepted the proposal.
  bool? get accepted => raw.getBool('accepted');
}

/// A safe HTTP/socket failure: never a response body or credential.
final class MatchException implements Exception {
  /// Creates a failure.
  const MatchException(this.status, this.code, {this.reason, this.retryAfter});

  /// HTTP status, or zero when no answer arrived.
  final int status;

  /// A service code or a fixed local failure code.
  final String code;

  /// The service's validated details.reason word.
  final String? reason;

  /// Cooldown supplied by the service.
  final Duration? retryAfter;
  @override
  String toString() => 'MatchException($code, $status)';
}

/// Options for a single live matchmaking channel.
final class LiveMatchClientOptions {
  /// Creates options. A new credential requires a new client.
  const LiveMatchClientOptions({
    required this.url,
    required this.channelId,
    required this.token,
    this.webSocketFactory,
    this.logger,
    this.timeout = const Duration(minutes: 10),
  });

  /// Match socket origin; never logged.
  final Uri url;

  /// Channel to queue in.
  final String channelId;

  /// Auth channel JWT, sent only as a subprotocol.
  final String token;

  /// Injectable transport; null selects the browser-compatible default.
  final GatewayWebSocketFactory? webSocketFactory;

  /// Diagnostic writer; null uses nullLogger.
  final Logger? logger;

  /// Upper bound on one find, including handshake and waiting.
  final Duration timeout;
}

/// A live socket submits on connection; terminal messages end the find.
abstract interface class LiveMatchClient {
  /// Creates a disconnected client.
  factory LiveMatchClient(LiveMatchClientOptions options) = LiveMatchClientImpl;

  /// Returns the active find or starts a new one.
  Future<MatchResult> find();

  /// Cancels the active find; the client may find again.
  void cancel();

  /// Closes the client permanently.
  Future<void> close();
}

/// Immutable options for the deferred HTTP surface.
final class DeferredMatchClientOptions {
  /// Creates options; ticketUrl must name this channel on apiBase.
  const DeferredMatchClientOptions({
    required this.apiBase,
    required this.channelId,
    required this.token,
    this.ticketUrl,
    this.client,
    this.logger,
    this.timeout = const Duration(seconds: 15),
  });

  /// The match API base, not the state API base.
  final Uri apiBase;

  /// Channel to queue in.
  final String channelId;

  /// Auth channel JWT.
  final String token;

  /// Optional kit-config ticket URL, validated against the base and channel.
  final Uri? ticketUrl;

  /// Injected HTTP client is never closed by this client.
  final http.Client? client;

  /// Diagnostic writer; null uses nullLogger.
  final Logger? logger;

  /// One deadline for headers and body.
  final Duration timeout;
}

/// Wire operations only: polling and retry policy belong to the game kit.
abstract interface class DeferredMatchClient {
  /// Creates an HTTP client without sending a request.
  factory DeferredMatchClient(DeferredMatchClientOptions options) =
      DeferredMatchClientImpl;

  /// Submits or replaces a waiting ticket.
  Future<MatchTicket> submit();

  /// Current ticket; null for an absent ticket (404).
  Future<MatchTicket?> status();

  /// Cancels a waiting ticket or declines a proposal, idempotently.
  Future<void> cancel();

  /// Accepts the current proposal.
  Future<MatchTicket> accept();

  /// Declines the current proposal.
  Future<MatchTicket> decline();

  /// Releases the owned HTTP client.
  void close();
}

/// One authenticated presence answer.
final class GatewayPresence {
  /// Creates a presence item.
  const GatewayPresence(this.userId, this.online);

  /// The requested player.
  final String userId;

  /// Whether that player has a lobby socket now; only a hint.
  final bool online;
}

/// Immutable options for the gateway HTTP presence surface.
final class GatewayPresenceClientOptions {
  /// Creates options.
  const GatewayPresenceClientOptions({
    required this.baseUrl,
    required this.channelId,
    required this.token,
    this.client,
    this.logger,
    this.timeout = const Duration(seconds: 15),
  });

  /// Gateway HTTP origin.
  final Uri baseUrl;

  /// Lobby channel whose presence is queried.
  final String channelId;

  /// Auth channel JWT.
  final String token;

  /// Injected HTTP client, never closed here.
  final http.Client? client;

  /// Diagnostic writer; null uses nullLogger.
  final Logger? logger;

  /// One deadline for headers and body.
  final Duration timeout;
}

/// Batch presence for a friends list, independent of the lobby socket.
abstract interface class GatewayPresenceClient {
  /// Creates a client without sending a request.
  factory GatewayPresenceClient(GatewayPresenceClientOptions options) =
      GatewayPresenceClientImpl;

  /// Queries at most 50 player identities.
  Future<List<GatewayPresence>> users(List<String> ids);

  /// Releases the owned HTTP client.
  void close();
}
