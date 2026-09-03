/// One thing a socket reported. Delivered in order on
/// [GatewayWebSocket.events].
sealed class SocketEvent {
  const SocketEvent();
}

/// The handshake completed. [protocol] is the subprotocol the server chose,
/// or `null` when it chose none.
final class SocketOpened extends SocketEvent {
  /// Creates an opened event.
  const SocketOpened(this.protocol);

  /// The negotiated subprotocol.
  final String? protocol;
}

/// A text frame arrived, already assembled.
final class SocketTextMessage extends SocketEvent {
  /// Creates a text message event.
  const SocketTextMessage(this.text);

  /// The frame body. Never log it: it is whatever the peer sent.
  final String text;
}

/// A binary frame arrived. The gateway never sends one; the SDK reports a
/// protocol error and ignores the payload, which is why it is not carried.
final class SocketBinaryMessage extends SocketEvent {
  /// Creates a binary message event.
  const SocketBinaryMessage();
}

/// The socket is closed. Exactly one per socket, always last. A handshake
/// that never completed reports `1006`.
final class SocketClosed extends SocketEvent {
  /// Creates a closed event.
  const SocketClosed(this.code, this.reason);

  /// The close code.
  final int code;

  /// The close reason. Never log its text — the peer may quote what the
  /// client sent back into it. Log its length.
  final String reason;
}

/// What a [GatewayWebSocketFactory] is asked to open.
final class GatewayWebSocketRequest {
  /// Creates a request.
  const GatewayWebSocketRequest({
    required this.url,
    required this.subprotocols,
  });

  /// The gateway URL with the `channel` (and `gameId`) query.
  final Uri url;

  /// Always `['bearer', token]`.
  ///
  /// **The second entry is the raw channel JWT.** It crosses this extension
  /// point because the handshake is the only place it may go. An
  /// implementation hands it to the WebSocket handshake and nowhere else:
  /// not a log, not the URL, not a persisted field, not an exception
  /// message.
  final List<String> subprotocols;
}

/// A single WebSocket connection as the state machine sees it.
///
/// Contract for an implementation:
/// - [events] is single-subscription and delivers, in order, an optional
///   [SocketOpened], any number of messages, then exactly one
///   [SocketClosed], then completes. Every failure after construction — a
///   refused handshake, a network error, a timeout — arrives as a
///   [SocketClosed] (code `1006` when the peer sent none), never as a
///   stream error.
/// - [send] is fire-and-forget on an open socket.
/// - [close] sends a close frame with [code] (`1000` or `3000`–`4999`) and
///   [reason]; the [SocketClosed] that follows reports the code the
///   *client* asked for, so the state machine's own close codes are what it
///   sees back.
abstract interface class GatewayWebSocket {
  /// The event stream. See the class contract.
  Stream<SocketEvent> get events;

  /// Sends a text frame.
  void send(String text);

  /// Starts a close handshake.
  void close(int code, String reason);
}

/// Opens sockets. Inject one to test without a network or to use a
/// platform-specific WebSocket; the default uses `package:web_socket_channel`
/// and works on every Flutter platform including web.
abstract interface class GatewayWebSocketFactory {
  /// Opens a socket. May throw synchronously for a request it can refuse
  /// before connecting (a malformed subprotocol, a bad URL); the SDK reports
  /// that as a stop. Anything after that must come through [GatewayWebSocket.events].
  GatewayWebSocket connect(GatewayWebSocketRequest request);
}
