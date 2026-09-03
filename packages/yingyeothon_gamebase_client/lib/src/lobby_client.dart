import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import 'client_events.dart';
import 'internal/lobby_client_impl.dart';
import 'protocol/capabilities.dart';
import 'protocol/frame_types.dart';
import 'protocol/hello.dart';
import 'protocol/peer.dart';
import 'protocol/peer_map.dart';
import 'protocol/server_frames.dart';
import 'transport/http_fetcher.dart';

/// Options for a [GatewayLobbyClient].
final class GatewayLobbyClientOptions extends GatewayClientOptions {
  /// Creates lobby options.
  const GatewayLobbyClientOptions({
    required super.url,
    required super.channelId,
    required super.token,
    super.webSocketFactory,
    super.backoff,
    super.maxHandshakeFailures,
    super.logger,
    this.httpFetcher,
    this.helloTimeoutMs = 10000,
  });

  /// Used by [GatewayLobbyClient.map]; defaults to `package:http` with a
  /// 30 s timeout, a 16 MiB cap and 5 redirects.
  final MapHttpFetcher? httpFetcher;

  /// How long to wait for `hello` after the socket opens. On expiry that
  /// socket is closed and the reconnect policy runs; `connect()` keeps
  /// waiting.
  final int helloTimeoutMs;
}

/// The `party.*` senders. Each is refused locally when `hello` said the
/// channel has parties off.
abstract interface class PartyCommands {
  /// `party.create`.
  void create();

  /// `party.invite`.
  void invite(String userId);

  /// `party.accept`.
  void accept(String partyId);

  /// `party.decline`.
  void decline(String partyId);

  /// `party.leave`.
  void leave();

  /// `party.list`.
  void list();
}

/// Lobby client: connects with the bearer subprotocol, waits for `hello`
/// before reporting a connection, maintains the peer map from the gateway's
/// `snapshot` / `enter` / `leave` / `pos` frames, and exposes typed senders.
///
/// After a reconnect the peer map is empty until the game re-sends `pos`
/// and the gateway answers with a fresh `snapshot`. Every stream is a
/// synchronous broadcast: a listener added before `connect()` sees every
/// event, in the order the gateway sent them.
abstract interface class GatewayLobbyClient {
  /// Creates a client. Nothing connects until [connect].
  factory GatewayLobbyClient(GatewayLobbyClientOptions options) =
      LobbyClientImpl;

  /// Where the connection is.
  GatewayClientState get state;

  /// Every change of [state].
  Stream<GatewayClientState> get stateChanges;

  /// The latest `hello`, once connected.
  Hello? get hello;

  /// `hello.capabilities`, once connected.
  Capabilities? get capabilities;

  /// Current party id, from `hello.partyId` or the latest `party` frame;
  /// `null` when in none.
  String? get partyId;

  /// The latest `party` roster frame, if any since the last `hello`.
  PartyFrame? get roster;

  /// Peers in view. Replaced by every `hello`; cleared on disconnect.
  PeerMap get peers;

  /// Opens the connection. Completes with `hello`; fails with
  /// [GatewayStoppedException] if the connection stops before that. Always
  /// `await` or `catchError` it. Throws [StateError] synchronously when
  /// called a second time.
  Future<Hello> connect();

  /// Closes for good and releases every stream. Idempotent.
  Future<void> close();

  /// Fetches `hello.mapUrl`, cached per URL for the client's life. Throws
  /// [StateError] before `hello` and [MapFetchException] on failure.
  Future<Object?> map();

  /// Announces a position. Throws [StateError] when the channel has `pos`
  /// off and [ArgumentError] when [dir] exceeds 16 bytes.
  void pos({
    required String zone,
    required double x,
    required double y,
    String? dir,
  });

  /// Chat. Throws [StateError] when the channel does not allow [scope].
  void say({required SayScope scope, required String text, String? to});

  /// A game event. Throws [StateError] when `event` is off or [scope] is
  /// not allowed. A `null` [payload] is omitted from the frame.
  void event({
    required SayScope scope,
    required String name,
    Object? payload,
    String? to,
  });

  /// The party senders.
  PartyCommands get party;

  /// `ping`; the gateway answers on [pong].
  void ping();

  /// Escape hatch: sends any frame. Throws [StateError] unless connected.
  void send(JsonObject frame);

  /// `hello` arrived; also after every successful reconnect.
  Stream<Hello> get connected;

  /// The socket went away; [DisconnectedEvent.willReconnect] says whether a
  /// retry follows.
  Stream<DisconnectedEvent> get disconnected;

  /// A retry is scheduled.
  Stream<ReconnectingEvent> get reconnecting;

  /// Terminal.
  Stream<StoppedEvent> get stopped;

  /// A `snapshot` replaced the peer map.
  Stream<SnapshotFrame> get snapshots;

  /// A peer came into view.
  Stream<Peer> get peerEntered;

  /// A peer left the view (its user id).
  Stream<String> get peerLeft;

  /// Peers moved this tick.
  Stream<List<Peer>> get peerMoved;

  /// Chat arrived.
  Stream<SayBroadcastFrame> get said;

  /// A game event arrived.
  Stream<EventBroadcastFrame> get eventReceived;

  /// The roster changed.
  Stream<PartyFrame> get partyChanged;

  /// You were invited.
  Stream<PartyInviteFrame> get partyInvited;

  /// (Leader) an invite was declined.
  Stream<PartyDeclinedFrame> get partyDeclined;

  /// `pong`.
  Stream<void> get pong;

  /// The gateway refused something you sent. Log the code, not the message.
  Stream<ErrorFrame> get refused;

  /// A frame that was not the protocol. The connection stays up.
  Stream<ProtocolErrorEvent> get protocolErrors;

  /// Every frame after `hello`, before any SDK handling; a `party` frame is
  /// already filled in.
  Stream<LobbyServerFrame> get frames;
}
