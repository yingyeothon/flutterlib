import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import 'client_events.dart';
import 'internal/game_client_impl.dart';
import 'protocol/server_frames.dart';

/// Options for a [GatewayGameClient].
final class GatewayGameClientOptions extends GatewayClientOptions {
  /// Creates game options.
  const GatewayGameClientOptions({
    required super.url,
    required super.channelId,
    required super.token,
    required this.gameId,
    super.webSocketFactory,
    super.backoff,
    super.maxHandshakeFailures,
    super.logger,
  });

  /// The run to join; you must be in its start event's members.
  final String gameId;
}

/// Dungeon (`q`) client. The gateway defines no vocabulary here — every
/// frame belongs to the game — so this is a passthrough whose only protocol
/// knowledge is the connect sequence, the reserved inbound types, and the
/// difference between an aborted run (`4001`) and a finished one (`1000`).
/// Neither of those reconnects; a retry needs a fresh `gameId`.
abstract interface class GatewayGameClient {
  /// Creates a client. Nothing connects until [connect].
  factory GatewayGameClient(GatewayGameClientOptions options) = GameClientImpl;

  /// Where the connection is.
  GatewayClientState get state;

  /// Every change of [state].
  Stream<GatewayClientState> get stateChanges;

  /// Opens the connection. Completes once the socket is open with `bearer`
  /// echoed; fails with [GatewayStoppedException] if it stops first.
  Future<void> connect();

  /// Closes for good and releases every stream. Idempotent.
  Future<void> close();

  /// Sends a game frame. Throws [StateError] unless connected, or when the
  /// frame's `type` is `enter` or `leave` (the gateway's own bookkeeping).
  void send(JsonObject frame);

  /// The socket is open and the gateway has pushed `enter` to the actor.
  /// Fires again after a reconnect; the game answers with its own snapshot.
  /// The client is already usable inside a handler, so the first frame can
  /// be sent from here.
  Stream<void> get connected;

  /// Every game-defined frame, verbatim — any JSON value, not only objects.
  Stream<Object?> get frames;

  /// A gateway refusal (`{type: "error", code, message}`).
  Stream<ErrorFrame> get refused;

  /// The socket went away.
  Stream<DisconnectedEvent> get disconnected;

  /// A retry is scheduled.
  Stream<ReconnectingEvent> get reconnecting;

  /// Close `4001`: the actor died. Retry only with a new `gameId`.
  Stream<GameEndedEvent> get aborted;

  /// Close `1000`: the game dropped this connection after ending normally.
  Stream<GameEndedEvent> get finished;

  /// Any other terminal close (replaced, policy, channel gone, retries
  /// exhausted, handshake refused).
  Stream<StoppedEvent> get stopped;

  /// A frame that was not JSON.
  Stream<ProtocolErrorEvent> get protocolErrors;
}
