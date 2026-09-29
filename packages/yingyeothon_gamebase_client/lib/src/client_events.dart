import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'backoff.dart';
import 'protocol/close_codes.dart';
import 'protocol/frame_types.dart';
import 'transport/web_socket.dart';

/// Where a client is in its life.
enum GatewayClientState {
  /// Created, `connect()` not called.
  idle,

  /// First socket opening (lobby: or waiting for `hello`).
  connecting,

  /// Usable; `send` works.
  connected,

  /// Between sockets, a retry scheduled.
  reconnecting,

  /// Terminal: stopped by the gateway's policy, by `close()`, or by
  /// exhausted retries.
  closed,
}

/// The socket went away.
final class DisconnectedEvent {
  /// Creates a disconnected event.
  const DisconnectedEvent({
    required this.code,
    required this.reason,
    required this.willReconnect,
  });

  /// The close code.
  final int code;

  /// An SDK-authored explanation — never the peer's close reason text.
  final String reason;

  /// Whether a reconnect is scheduled. A `close()` from this event's
  /// handler cancels it.
  final bool willReconnect;
}

/// A reconnect is scheduled.
final class ReconnectingEvent {
  /// Creates a reconnecting event.
  const ReconnectingEvent({required this.attempt, required this.delayMs});

  /// Consecutive attempt number, from 1.
  final int attempt;

  /// Delay before it, in ms.
  final int delayMs;
}

/// The connection ended for good; no reconnect will follow.
final class StoppedEvent {
  /// Creates a stopped event.
  const StoppedEvent({
    required this.kind,
    required this.reason,
    required this.code,
  });

  /// Why, as a policy.
  final CloseDispositionKind kind;

  /// An SDK-authored explanation.
  final String reason;

  /// The close code, or `0` when no socket ever closed.
  final int code;
}

/// Something arrived that is not the protocol. The connection stays up;
/// the frame is ignored. [message] is SDK-authored; a peer-chosen fragment
/// in it is capped and stripped of control characters.
final class ProtocolErrorEvent {
  /// Creates a protocol error event.
  const ProtocolErrorEvent(this.message);

  /// What was wrong.
  final String message;
}

/// `q`: the run ended — [GatewayGameClient.aborted] or `finished`.
final class GameEndedEvent {
  /// Creates a game-ended event.
  const GameEndedEvent({required this.code, required this.reason});

  /// The close code (`4001` or `1000`).
  final int code;

  /// An SDK-authored explanation.
  final String reason;
}

/// `connect()` failed: the connection stopped before it became usable.
final class GatewayStoppedException implements Exception {
  /// Creates the exception.
  const GatewayStoppedException(this.message);

  /// An SDK-authored explanation.
  final String message;

  @override
  String toString() => 'GatewayStoppedException: $message';
}

/// Why a sender refused a frame locally. Each value is the refusal the
/// gateway would have sent for the same frame, named by [wire].
enum GatewayClientErrorCode {
  /// `hello.capabilities` has that feature, or that `say` scope, off.
  capabilityOff(GatewayErrorCode.capabilityOff),

  /// `q`: the frame's `type` is `enter` or `leave`, the gateway's own.
  reservedType(GatewayErrorCode.reservedType),

  /// `q`: the frame has no string `type`.
  badMessage(GatewayErrorCode.badMessage);

  const GatewayClientErrorCode(this.wire);

  /// The gateway's refusal code for the same frame.
  final String wire;
}

/// A sender refused a frame before anything reached the wire, because the
/// gateway would refuse it too. The connection is unaffected. Not connected
/// is a [StateError], a bad argument an [ArgumentError]; this is neither.
final class GatewayClientException implements Exception {
  /// Creates the exception.
  const GatewayClientException(this.code, this.message);

  /// Which refusal.
  final GatewayClientErrorCode code;

  /// An SDK-authored explanation; never quotes the frame.
  final String message;

  @override
  String toString() => 'GatewayClientException(${code.wire}): $message';
}

/// Options both clients share. Immutable; a client copies what it needs at
/// construction, so a new token means a new client.
abstract base class GatewayClientOptions {
  /// Creates the shared options.
  const GatewayClientOptions({
    required this.url,
    required this.channelId,
    required this.token,
    this.webSocketFactory,
    this.backoff,
    this.maxHandshakeFailures = 5,
    this.logger,
  });

  /// Gateway origin, e.g. `wss://gw.yyt.life`. The SDK adds the query.
  final String url;

  /// The channel id from the console.
  final String channelId;

  /// The channel JWT. It rides in the subprotocol list and is never logged.
  final String token;

  /// Opens sockets; defaults to `package:web_socket_channel`.
  final GatewayWebSocketFactory? webSocketFactory;

  /// Reconnect timing; defaults to 500 ms doubling to 15 s with 20% jitter.
  final BackoffOptions? backoff;

  /// Consecutive closes-before-open that end the session. A refused
  /// handshake (401/403/404/410) looks like one, so this is what keeps a
  /// dead token from retrying forever.
  final int maxHandshakeFailures;

  /// Where the SDK logs ids, codes and counts. Defaults to `nullLogger`.
  final Logger? logger;
}
