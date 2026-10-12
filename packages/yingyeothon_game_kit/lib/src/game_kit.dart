import 'package:http/http.dart' as http;
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

import 'internal/game_kit_impl.dart';

/// A console kit-config block. Values are public; never include credentials.
final class GameKitConfig {
  /// Copies a JSON config so subsequent caller mutations cannot change routing.
  GameKitConfig(JsonObject value)
    : raw = Map.unmodifiable(Json.decode(Json.encode(value))! as JsonObject);

  /// Public configuration sections and game aliases.
  final JsonObject raw;
}

/// A purpose-shaped error. Cause contains only safe status/code metadata.
final class KitError implements Exception {
  /// Creates a failure without wire payloads or credentials.
  const KitError(this.module, this.code, {this.retryable = false, this.status});

  /// Module that refused the operation.
  final String module;

  /// Language-neutral code from the service's game-kit-design table.
  final String code;

  /// Whether the game can retry after correcting availability/conflicts.
  final bool retryable;

  /// Safe transport status, when known.
  final int? status;
  @override
  String toString() => 'KitError($module, $code)';
}

/// Merge must be deterministic; the remote value may be absent/null.
typedef KitMerge = Object? Function(Object? local, Object? remote);

/// A durable conditional write, isolated by config and identity.
final class KitQueuedWrite {
  /// Creates a JSON-valued queue record.
  const KitQueuedWrite({
    required this.id,
    required this.name,
    required this.kind,
    this.value,
    this.expectedVersion,
    this.ttl,
  });

  /// Stable queue record id.
  final String id;

  /// Save name.
  final String name;

  /// store or remove; counters/claims are never queued.
  final String kind;

  /// Desired stored JSON value.
  final Object? value;

  /// Expected version; null means create-only.
  final int? expectedVersion;

  /// TTL in seconds.
  final int? ttl;
}

/// Mobile opt-in durable queue adapter; host storage is outside the SDK.
abstract interface class KitQueueStorage {
  /// Reads the isolated queue.
  Future<List<KitQueuedWrite>> load(String namespace);

  /// Atomically persists the entire queue before acknowledging a write.
  Future<void> store(String namespace, List<KitQueuedWrite> writes);
}

/// Immutable options for all modules. Platform glue is injected by the app.
final class GameKitOptions {
  /// Creates options. Modules connect lazily and share one session/HTTP client.
  const GameKitOptions({
    required this.config,
    this.session,
    this.login,
    this.tokenStorage,
    this.queueStorage,
    this.mergePolicies = const {},
    this.client,
    this.webSocketFactory,
    this.lobbyFactory,
    this.pushMessaging,
    this.firebaseProject,
    this.logger,
    this.monotonicMilliseconds,
    this.contentInterval = const Duration(seconds: 60),
    this.mailInterval = const Duration(seconds: 30),
    this.matchInterval = const Duration(seconds: 4),
    this.roomTimeout = const Duration(seconds: 10),
    this.matchCallback = false,
    this.maxMergeRetries = 3,
    this.maxLogBytes = 1048576,
    this.logTtlSeconds = 604800,
  });

  /// Public console configuration.
  final GameKitConfig config;

  /// Existing session, owned by the caller; null creates an owned session.
  final AuthSession? session;

  /// Host login flow, including nonce verification and redirect handling.
  final Future<ChannelToken> Function()? login;

  /// Optional secure store; use null on shared web origins.
  final AuthTokenStorage? tokenStorage;

  /// Durable queue, opt-in on mobile.
  final KitQueueStorage? queueStorage;

  /// Save-name merge policies used after queue restoration.
  final Map<String, KitMerge> mergePolicies;

  /// Shared HTTP transport; injected clients remain caller-owned.
  final http.Client? client;

  /// Injectable browser-compatible socket transport.
  final GatewayWebSocketFactory? webSocketFactory;

  /// Optional factory for the kit-owned lobby, allowing the game to retain
  /// its wire client for position/chat on the same socket. Recreated per token.
  /// Options carry the raw JWT: pass it only to the transport, never to logs.
  final GatewayLobbyClient Function(GatewayLobbyClientOptions)? lobbyFactory;

  /// Injected device SDK; Flutter/Firebase stays in the host app.
  final PushMessaging? pushMessaging;

  /// Embedded Firebase project id, always sent during push registration.
  final String? firebaseProject;

  /// Safe diagnostics, default nullLogger.
  final Logger? logger;

  /// Monotonic milliseconds for deterministic tests.
  final int Function()? monotonicMilliseconds;

  /// Content polling, default sixty seconds.
  final Duration contentInterval;

  /// Mail/friends polling, default thirty seconds.
  final Duration mailInterval;

  /// Deferred status polling, between three and five seconds by default.
  final Duration matchInterval;

  /// Bound on room roster acknowledgement.
  final Duration roomTimeout;

  /// Explicit live callback channel selection, never inferred from result.
  final bool matchCallback;

  /// Maximum conflict merge retries for one conditional save.
  final int maxMergeRetries;

  /// Maximum staged turns log bytes during resync.
  final int maxLogBytes;

  /// Persisted turn log TTL, seconds.
  final int logTtlSeconds;
}

/// One kit credential/config with purpose-shaped modules and lazy connections.
abstract interface class GameKit {
  /// Creates a kit. Module config is checked at first use, not eagerly.
  factory GameKit(GameKitOptions options) = GameKitImpl;

  /// Shared identity and monotonic platform clock.
  AuthSession get session;

  /// Public tuning data cache.
  KitContent get content;

  /// Player's conditional persistent save.
  KitSave get save;

  /// One lobby-backed room with host authority by agreement.
  KitRoom get room;

  /// Turn game factory over room.
  KitTurns get turns;

  /// Board selected by game alias.
  KitBoard board(String alias);

  /// Player inbox.
  KitMail get mail;

  /// Social relationships joined with presence.
  KitFriends get friends;

  /// Live room formation or deferred tickets selected from configuration.
  KitMatchmaking get matchmaking;

  /// Android device registration/message module.
  KitPush get push;

  /// Module failures from asynchronous refresh, polling and persistence.
  Stream<KitError> get refused;

  /// Host app calls on visibility/lifecycle changes; stops background polling.
  void setForeground(bool foreground);

  /// Closes all owned resources; injected transports/session stay caller-owned.
  Future<void> close();
}

/// Read-only cached project content.
abstract interface class KitContent {
  /// Cached value returned immediately, refreshed in background; absent is null.
  Future<Object?> get(String key);

  /// Lists values across all pages, optionally filtered by prefix.
  Future<Map<String, Object?>> list({String? prefix});

  /// Watches one key, emitting only when the entry version changes.
  Stream<Object?> subscribe(String key);
}

/// Conditional per-player save, with optional durable offline writes.
abstract interface class KitSave {
  /// Reads value and remembers version, or null for absence.
  Future<Object?> load(String name);

  /// Writes against the remembered version; merges conflicting state if given.
  Future<void> store(String name, Object? value, {KitMerge? merge, int? ttl});

  /// Reads, transforms and conditionally stores.
  Future<void> update(
    String name,
    Object? Function(Object?) transform, {
    KitMerge? merge,
  });

  /// Conditional removal of the remembered entry.
  Future<void> remove(String name);

  /// Atomic counter, never queued offline.
  KitCounter counter(String name);

  /// True once per TTL window, using create-only server semantics.
  Future<bool> claimOnce(String name, int ttl);

  /// Number of loaded durable queue records.
  int get pendingCount;

  /// Replays queued records in order; preserves and stops on unresolved conflict.
  Future<void> flush();
}

/// Atomic save counter.
abstract interface class KitCounter {
  /// Adds without crossing optional bounds; returns the stored result.
  Future<int> add(int delta, {int? min, int? max});
}

/// A member mirrored from the gateway party roster.
final class KitMember {
  /// Creates a roster item.
  const KitMember(this.userId, this.online);

  /// Authenticated player id.
  final String userId;

  /// Online hint.
  final bool online;
}

/// An authenticated game event; reserved kit events are never exposed here.
final class KitRoomEvent {
  /// Creates an event.
  const KitRoomEvent(this.name, this.from, this.payload);

  /// Game-defined name.
  final String name;

  /// Gateway-authenticated sender.
  final String from;

  /// JSON game payload.
  final Object? payload;
}

/// Room invite that may be accepted or declined once by the consumer.
abstract interface class KitInvitation {
  /// Room to join.
  String get roomId;

  /// Authenticated inviter.
  String get from;

  /// Accepts invitation and waits for roster acknowledgement.
  Future<void> accept();

  /// Declines invitation.
  Future<void> decline();
}

/// Host-authoritative party abstraction. Authority is by agreement, not arbitration.
abstract interface class KitRoom {
  /// Opens the shared lobby without creating a room, required before live find.
  Future<void> connect();

  /// Creates a room and waits until the creator is host.
  Future<void> create();

  /// Invites an online player.
  Future<void> invite(String userId);

  /// Leaves the room.
  Future<void> leave();

  /// Current room id, null when not in a room.
  String? get id;

  /// Current host, null when no room.
  String? get host;

  /// Whether the local player is host.
  bool get isHost;

  /// Immutable member roster.
  List<KitMember> get members;

  /// Incoming invites.
  Stream<KitInvitation> get invited;

  /// Roster additions.
  Stream<KitMember> get memberJoined;

  /// Roster removals.
  Stream<KitMember> get memberLeft;

  /// Online-hint changes.
  Stream<KitMember> get memberOnline;

  /// Host changes.
  Stream<String> get hostChanged;

  /// Last known snapshot delivered to a new local host.
  Stream<Object?> get becameHost;

  /// User game events, excluding kit.*.
  Stream<KitRoomEvent> get events;

  /// Sends a game event to the party; full envelope must fit 8192 UTF-8 bytes.
  Future<void> send(String name, Object? payload);

  /// Sends a game event to one room member.
  Future<void> whisper(String userId, String name, Object? payload);

  /// Host-only latest snapshot publishing.
  Future<void> publish(Object? snapshot);

  /// Snapshots accepted only from the current host.
  Stream<Object?> get state;

  /// Asks current host for its latest snapshot.
  Future<void> resync();
}

/// Turn factory; every peer supplies the same initial state and pure reducer.
abstract interface class KitTurns {
  /// Starts or attaches to a host-announced game; players default to room roster.
  /// With persistence, resumes the saved game unless resume is false.
  Future<KitTurnGame> start({
    required Object? initial,
    required Object? Function(Object? state, Object? move, String by) apply,
    List<String>? players,
    bool persist = false,
    bool resume = true,
    String? saveResultAs,
    String? resultBoard,
    int Function(Object?)? scoreForResult,
  });
}

/// Deterministic turn log with verified recovery and host finish agreement.
abstract interface class KitTurnGame {
  /// Current reducer state.
  Object? get state;

  /// Index of next move, starts at zero.
  int get index;

  /// True once the verified terminal result has been received or announced.
  bool get finished;

  /// The terminal JSON result; null is also a valid finished result.
  Object? get result;

  /// True after a divergence; submit is frozen.
  bool get frozen;

  /// Per-player informational monotonic elapsed milliseconds.
  Map<String, int> get elapsed;

  /// Submits only on the local player's turn.
  Future<void> submit(Object? move);

  /// Changed state after a validated move.
  Stream<KitTurnEvent> get turned;

  /// Hash/reducer/log divergence, freezes the game.
  Stream<KitError> get mismatch;

  /// Host announces finish; each player persists its own result.
  Future<void> finish(Object? result);

  /// Stages and validates a peer/persisted log before replacing state.
  Future<void> resync();

  /// Stops this turn game's subscriptions and timers.
  Future<void> close();
}

/// One validated move notification.
final class KitTurnEvent {
  /// Creates a move event.
  const KitTurnEvent({
    required this.state,
    required this.move,
    required this.by,
    required this.index,
  });

  /// Reducer state after the move.
  final Object? state;

  /// Accepted move payload.
  final Object? move;

  /// Authenticated mover.
  final String by;

  /// Zero-based move index.
  final int index;
}

/// One leaderboard row using game vocabulary.
final class KitScore {
  /// Creates a ranked score.
  const KitScore({
    required this.userId,
    required this.score,
    this.rank,
    this.period,
    this.meta,
    this.total,
    this.endsAt,
  });

  /// Scoring player.
  final String userId;

  /// Stored integer score.
  final int score;

  /// One-based rank; null when an acknowledged submission's rank read failed.
  final int? rank;

  /// Period name for submissions and ranked reads.
  final String? period;

  /// Game metadata encoded by the game.
  final String? meta;

  /// Total entries, when supplied by the service.
  final int? total;

  /// Platform epoch seconds; null for alltime.
  final int? endsAt;
}

/// A board alias, independent of state route details.
abstract interface class KitBoard {
  /// All configured period names, loaded by info or submit.
  List<String> get periods;

  /// best, latest or sum, loaded by info.
  String? get rule;

  /// asc or desc, loaded by info.
  String? get order;

  /// Loads configuration and current period names.
  Future<void> info();

  /// Writes own score on an owner board; server boards refuse server_only.
  Future<List<KitScore>> submit(int score, {String? meta});

  /// Ranked page.
  Future<List<KitScore>> top(String period, {int limit = 20, int offset = 0});

  /// Own ranked row, null when absent.
  Future<KitScore?> me(String period);

  /// Own row and neighbours; clamps offset at rank one.
  Future<List<KitScore>> around(String period, {int span = 2});
}

/// A stamped inbox letter.
final class KitLetter {
  /// Creates a letter.
  const KitLetter({
    required this.id,
    required this.from,
    required this.at,
    required this.value,
    this.expiresAt,
  });

  /// Create-only mail key.
  final String id;

  /// Platform writer stamp, server/team/player.
  final String? from;

  /// Update time as epoch seconds.
  final int? at;

  /// JSON content chosen by sender.
  final Object? value;

  /// Expiry as epoch seconds, null for none.
  final int? expiresAt;
}

/// A player inbox; rewards are applied by the game after a successful claim.
abstract interface class KitMail {
  /// All letters, newest first.
  Future<List<KitLetter>> list();

  /// One letter, null for absence.
  Future<KitLetter?> read(String id);

  /// Conditional deletion returns the letter to exactly one claimant.
  Future<KitLetter> claim(String id);

  /// Removes a letter.
  Future<void> remove(String id);

  /// Create-only player mail, with a kit-minted sender-prefixed key.
  Future<void> send(String to, Object? value, {int? ttl});

  /// New letters across foreground polls, once per letter id.
  Stream<KitLetter> get arrived;
}

/// A social friend joined with gateway presence.
final class KitFriend {
  /// Creates a friend.
  const KitFriend({
    required this.userId,
    required this.online,
    this.displayName,
    this.avatar,
  });

  /// Authenticated player id.
  final String userId;

  /// Presence hint; not authorization.
  final bool online;

  /// Peer-controlled display name, validate before display.
  final String? displayName;

  /// Peer-controlled avatar identifier.
  final String? avatar;
}

/// Social requests by identity.
final class KitFriendRequests {
  /// Copies requests.
  KitFriendRequests({
    required List<String> incoming,
    required List<String> outgoing,
  }) : incoming = List.unmodifiable(incoming),
       outgoing = List.unmodifiable(outgoing);

  /// Players asking to be friends.
  final List<String> incoming;

  /// Players asked by this player.
  final List<String> outgoing;
}

/// Social relationships and profiles; invites use the same room module.
abstract interface class KitFriends {
  /// Joins every relation with presence, batching no more than fifty ids.
  Future<List<KitFriend>> list();

  /// Incoming/outgoing request identities.
  Future<KitFriendRequests> requests();

  /// Requests friendship.
  Future<void> request(String userId);

  /// Accepts incoming request.
  Future<void> accept(String userId);

  /// Declines incoming request.
  Future<void> decline(String userId);

  /// Removes friendship.
  Future<void> remove(String userId);

  /// Blocks a player.
  Future<void> block(String userId);

  /// Unblocks a player.
  Future<void> unblock(String userId);

  /// Own profile, null when absent.
  Future<KitFriend?> myProfile();

  /// Sets own profile.
  Future<void> setProfile(String displayName, {String? avatar});

  /// Reads at most fifty profiles; cached identities remain ordered.
  Future<List<KitFriend>> profiles(List<String> ids);

  /// Invites through room.
  Future<void> invite(String userId);

  /// Newly observed incoming requests, polling while in foreground.
  Stream<String> get requested;
}

/// Purpose-shaped matched party without wire frames.
final class KitMatch {
  /// Copies matched members.
  KitMatch({
    required this.matchId,
    required List<String> members,
    required this.partial,
    this.result,
  }) : members = List.unmodifiable(members);

  /// Match identity.
  final String matchId;

  /// Participants in ticket order.
  final List<String> members;

  /// True for partial server matching or incomplete room join.
  final bool partial;

  /// Callback result, untouched.
  final Object? result;
}

/// Deferred status using game vocabulary.
final class KitMatchStatus {
  /// Creates a ticket status.
  const KitMatchStatus({
    required this.state,
    this.match,
    this.matchId,
    this.acceptBy,
    this.accepted,
  });

  /// waiting/proposed/confirmed/expired/declined/failed.
  final String state;

  /// Shared confirmed result.
  final KitMatch? match;

  /// Proposal/match identity when present.
  final String? matchId;

  /// Proposal deadline in epoch seconds.
  final int? acceptBy;

  /// Whether local player accepted.
  final bool? accepted;
}

/// Live room formation and deferred ticket lifecycle.
abstract interface class KitMatchmaking {
  /// Live-only: waits for result and forms a callback-less room, bounded by timeout.
  Future<KitMatch> find({Duration timeout = const Duration(minutes: 10)});

  /// Cancels live find or deferred ticket.
  Future<void> cancel();

  /// Deferred-only: submits and starts foreground polling.
  Future<KitMatchStatus> submit();

  /// Deferred status, null for absence.
  Future<KitMatchStatus?> status();

  /// Deferred acceptance.
  Future<KitMatchStatus> accept();

  /// Deferred decline.
  Future<KitMatchStatus> decline();

  /// Observed ticket changes; wakes always read HTTP.
  Stream<KitMatchStatus> get stateChanged;
}

/// Incoming device message; data never grants state or entitlements.
final class KitMessage {
  /// Copies data and classification.
  KitMessage({
    required Map<String, String> data,
    required this.matchWake,
    this.title,
    this.body,
  }) : data = Map.unmodifiable(data);

  /// Original message data.
  final Map<String, String> data;

  /// True for documented deferred match wake forms.
  final bool matchWake;

  /// Notification title, optional.
  final String? title;

  /// Notification body, optional.
  final String? body;
}

/// Android push registration and incoming messages.
abstract interface class KitPush {
  /// Starts the injected SDK and registers on every start.
  Future<void> start();

  /// Registers a caller-supplied device token.
  Future<void> register(String deviceToken);

  /// Deletes registration and unsubscribes before sign-out.
  Future<void> unregister();

  /// Incoming messages; match wakes are forwarded to matching too.
  Stream<KitMessage> get received;
}
