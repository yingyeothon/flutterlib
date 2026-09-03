import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'web_socket.dart';

/// Inbound text frames larger than this many **bytes** close the socket.
/// The gateway's outbound cap is 32 KiB; this is twice that.
const int maxInboundMessageBytes = 64 * 1024;

/// Time allowed for the handshake before the attempt is reported closed.
const Duration defaultHandshakeTimeout = Duration(seconds: 15);

/// The default [GatewayWebSocketFactory], over `package:web_socket_channel`,
/// so the same code runs on Android, iOS, desktop and web.
///
/// What it adds to the raw channel:
/// - the subprotocol list is validated for RFC 6455 token characters before
///   connecting, and a violation is reported by **index**, never by
///   character — the second entry is the credential;
/// - a failed or timed-out handshake is a [SocketClosed] with `1006`, and
///   the exception (whose message names the URL) is dropped;
/// - a text frame over [maxInboundMessageBytes] closes the socket locally
///   and is reported as `1009`;
/// - a close the client asked for is reported with the code it asked for;
/// - exactly one [SocketClosed] per socket.
final class WebSocketChannelFactory implements GatewayWebSocketFactory {
  /// Creates the factory.
  const WebSocketChannelFactory({
    this.handshakeTimeout = defaultHandshakeTimeout,
    this.maxMessageBytes = maxInboundMessageBytes,
  });

  /// See [defaultHandshakeTimeout].
  final Duration handshakeTimeout;

  /// See [maxInboundMessageBytes].
  final int maxMessageBytes;

  @override
  GatewayWebSocket connect(GatewayWebSocketRequest request) {
    for (var i = 0; i < request.subprotocols.length; i++) {
      final bad = _firstIllegalTokenChar(request.subprotocols[i]);
      if (bad >= 0) {
        throw ArgumentError(
          'subprotocol $i has an illegal character at index $bad',
        );
      }
    }
    if (!request.url.hasScheme ||
        (request.url.scheme != 'ws' && request.url.scheme != 'wss')) {
      throw ArgumentError('gateway url must be ws:// or wss://');
    }
    return _ChannelSocket(request, handshakeTimeout, maxMessageBytes);
  }

  /// Index of the first character that is not an HTTP token character, or
  /// `-1`.
  static int _firstIllegalTokenChar(String value) {
    const separators = '()<>@,;:\\"/[]?={} \t';
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      if (c <= 0x20 ||
          c >= 0x7f ||
          separators.contains(String.fromCharCode(c))) {
        return i;
      }
    }
    return value.isEmpty ? 0 : -1;
  }
}

final class _ChannelSocket implements GatewayWebSocket {
  _ChannelSocket(this._request, this._handshakeTimeout, this._maxBytes) {
    // Connect now, not on listen: events are buffered until the subscriber
    // arrives, and a caller that awaits something else first must not
    // deadlock a handshake that never started.
    _controller = StreamController<SocketEvent>();
    scheduleMicrotask(_start);
  }

  final GatewayWebSocketRequest _request;
  final Duration _handshakeTimeout;
  final int _maxBytes;
  late final StreamController<SocketEvent> _controller;
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  int? _localCloseCode;
  String? _localCloseReason;
  bool _ready = false;
  bool _closedReported = false;

  @override
  Stream<SocketEvent> get events => _controller.stream;

  Future<void> _start() async {
    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(
        _request.url,
        protocols: _request.subprotocols,
      );
      _channel = channel;
      await channel.ready.timeout(_handshakeTimeout);
    } catch (_) {
      // WebSocketChannelException / WebSocketException / TimeoutException:
      // every one of them may name the URL. The close code is the whole story.
      _reportClosed(1006, '');
      return;
    }
    if (_controller.isClosed) return;
    _ready = true;
    final requestedCode = _localCloseCode;
    if (requestedCode != null) {
      // close() came during the handshake: finish it politely, report the
      // code that was asked for, and never say "opened".
      try {
        await channel.sink.close(requestedCode, _localCloseReason ?? '');
      } catch (_) {
        // The peer may already be gone.
      }
      _reportClosed(requestedCode, '');
      return;
    }
    final protocol = channel.protocol;
    _controller.add(
      SocketOpened(protocol == null || protocol.isEmpty ? null : protocol),
    );
    _subscription = channel.stream.listen(
      _onData,
      onError: (Object _) => _reportClosed(1006, ''),
      onDone: () => _reportClosed(
        _localCloseCode ?? channel.closeCode ?? 1005,
        _localCloseCode != null ? '' : (channel.closeReason ?? ''),
      ),
      cancelOnError: true,
    );
  }

  void _onData(Object? data) {
    if (data is String) {
      // A string shorter than the cap in UTF-16 units divided by 3 cannot
      // exceed the cap in UTF-8; only the rest is measured exactly.
      if (data.length > _maxBytes ~/ 3 &&
          utf8.encode(data).length > _maxBytes) {
        _localCloseCode = 1009;
        _channel?.sink.close(4900, 'frame too large');
        return;
      }
      _controller.add(SocketTextMessage(data));
    } else {
      _controller.add(const SocketBinaryMessage());
    }
  }

  void _reportClosed(int code, String reason) {
    if (_closedReported) return;
    _closedReported = true;
    if (!_controller.isClosed) {
      _controller.add(SocketClosed(code, reason));
      unawaited(_controller.close());
    }
    unawaited(_subscription?.cancel());
  }

  @override
  void send(String text) {
    _channel?.sink.add(text);
  }

  @override
  void close(int code, String reason) {
    if (code != 1000 && (code < 3000 || code > 4999)) {
      throw ArgumentError.value(code, 'code', 'must be 1000 or 3000-4999');
    }
    if (_localCloseCode != null) return;
    _localCloseCode = code;
    _localCloseReason = reason;
    final channel = _channel;
    if (channel == null || !_ready) {
      // Handshake still in flight: _start finishes it and reports this code,
      // or its failure reports 1006 first.
      return;
    }
    unawaited(channel.sink.close(code, reason));
  }
}
