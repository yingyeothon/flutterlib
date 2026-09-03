import 'dart:async';
import 'dart:collection';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

/// A socket the test drives as the server. Events are delivered
/// synchronously, so a test asserts right after the call.
final class FakeWebSocket implements GatewayWebSocket {
  FakeWebSocket(this.request);

  final GatewayWebSocketRequest request;
  // Broadcast + sync so delivery is immediate; a re-entrant add (the client
  // sends from a handler and the test answers from inside that) is queued
  // and drained before returning, so a test never needs to flush microtasks.
  final StreamController<SocketEvent> _controller =
      StreamController<SocketEvent>.broadcast(sync: true);
  final Queue<SocketEvent> _queue = Queue<SocketEvent>();
  bool _dispatching = false;

  /// Frames the client sent, decoded.
  final List<Object?> sent = <Object?>[];

  /// Raw text the client sent.
  final List<String> sentRaw = <String>[];

  /// The close the client asked for, if any.
  int? clientCloseCode;
  String? clientCloseReason;

  /// When true, a client close is not reported back until [flushClose].
  /// A real transport reports the close only after the handshake finishes,
  /// and events already queued still arrive in between.
  bool deferClose = false;
  bool _closed = false;
  bool _pendingLocalClose = false;

  @override
  Stream<SocketEvent> get events => _controller.stream;

  bool get isClosed => _closed;

  void serverOpen([String? protocol = 'bearer']) =>
      _add(SocketOpened(protocol));

  void serverSend(JsonObject frame) => serverSendRaw(Json.encode(frame));

  void serverSendRaw(String text) => _add(SocketTextMessage(text));

  void serverSendBinary() => _add(const SocketBinaryMessage());

  void serverClose(int code, [String reason = '']) => _close(code, reason);

  /// A network failure: close with 1006 and no reason.
  void serverError() => _close(1006, '');

  /// Delivers the deferred close.
  void flushClose() {
    if (!_pendingLocalClose) return;
    _pendingLocalClose = false;
    _close(clientCloseCode!, '');
  }

  void _add(SocketEvent event) {
    if (_closed) throw StateError('socket already closed');
    _dispatch(event);
  }

  void _close(int code, String reason) {
    if (_closed) return;
    _closed = true;
    _dispatch(SocketClosed(code, reason));
  }

  void _dispatch(SocketEvent event) {
    _queue.add(event);
    if (_dispatching) return;
    _dispatching = true;
    try {
      while (_queue.isNotEmpty) {
        final next = _queue.removeFirst();
        _controller.add(next);
        if (next is SocketClosed) unawaited(_controller.close());
      }
    } finally {
      _dispatching = false;
    }
  }

  @override
  void send(String text) {
    if (_closed) throw StateError('send on a closed socket');
    sentRaw.add(text);
    sent.add(Json.decode(text));
  }

  @override
  void close(int code, String reason) {
    if (code != 1000 && (code < 3000 || code > 4999)) {
      throw ArgumentError.value(code, 'code', 'must be 1000 or 3000-4999');
    }
    if (_closed || clientCloseCode != null) return;
    clientCloseCode = code;
    clientCloseReason = reason;
    if (deferClose) {
      _pendingLocalClose = true;
    } else {
      _close(code, '');
    }
  }
}

/// Creates [FakeWebSocket]s and keeps them for the test to drive.
final class FakeWebSocketFactory implements GatewayWebSocketFactory {
  final List<FakeWebSocket> sockets = <FakeWebSocket>[];

  /// When set, [connect] calls it instead of creating a fake.
  GatewayWebSocket Function(GatewayWebSocketRequest request)? createOverride;

  /// Applied to every new socket.
  bool deferClose = false;

  FakeWebSocket get latest => sockets.last;

  @override
  GatewayWebSocket connect(GatewayWebSocketRequest request) {
    final override = createOverride;
    if (override != null) return override(request);
    final socket = FakeWebSocket(request)..deferClose = deferClose;
    sockets.add(socket);
    return socket;
  }
}
