import 'dart:async';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../backoff.dart';
import '../client_events.dart';
import '../gateway_url.dart';
import '../protocol/close_codes.dart';
import '../protocol/frame_types.dart';
import '../protocol/hello.dart';
import '../protocol/normalize.dart';
import '../transport/web_socket.dart';
import '../transport/web_socket_channel_transport.dart';
import 'emitter.dart';

const String _bearerSubprotocol = 'bearer';

/// What the shared state machine needs to know.
final class GatewaySocketOptions {
  /// Creates socket options.
  const GatewaySocketOptions({
    required this.url,
    required this.channelId,
    required this.token,
    required this.kind,
    this.gameId,
    this.webSocketFactory,
    this.backoff,
    this.helloTimeoutMs = 10000,
    this.maxHandshakeFailures = 5,
    this.logger,
  });

  /// Gateway origin.
  final String url;

  /// Channel id.
  final String channelId;

  /// `q` only.
  final String? gameId;

  /// The channel JWT.
  final String token;

  /// Which protocol rides this socket.
  final GatewayChannelKind kind;

  /// Socket factory; `null` for the default transport.
  final GatewayWebSocketFactory? webSocketFactory;

  /// Backoff; `null` for the defaults.
  final BackoffOptions? backoff;

  /// Lobby only: how long to wait for `hello` after open.
  final int helloTimeoutMs;

  /// Consecutive closes-before-open that end the session.
  final int maxHandshakeFailures;

  /// Logger; `null` for [nullLogger].
  final Logger? logger;
}

/// The connection state machine both clients share: the bearer-subprotocol
/// handshake, the hello wait, the close-code policy, and reconnect with
/// backoff.
///
/// Dart is single-threaded, so there is no pump: every transition runs on
/// the event loop from a socket event or a timer, and events reach the
/// client through [Emitter]s that preserve order under re-entrancy.
final class GatewaySocket {
  /// Creates the state machine. Nothing happens until [connect].
  GatewaySocket(this._options)
    : _factory = _options.webSocketFactory ?? const WebSocketChannelFactory(),
      _backoff = Backoff(_options.backoff ?? const BackoffOptions()),
      _logger = _options.logger ?? nullLogger,
      _url = buildGatewayUrl(
        _options.url,
        _options.channelId,
        _options.gameId,
      ) {
    _logContext = <String, Object?>{
      'kind': _options.kind.name,
      'channelId': _options.channelId,
      if (_options.gameId != null) 'gameId': _options.gameId,
    };
  }

  final GatewaySocketOptions _options;
  final GatewayWebSocketFactory _factory;
  final Backoff _backoff;
  final Logger _logger;
  final Uri _url;
  late final JsonObject _logContext;

  final Emitter<void> _opened = Emitter<void>();
  final Emitter<Hello> _hello = Emitter<Hello>();
  final Emitter<Object?> _frame = Emitter<Object?>();
  final Emitter<DisconnectedEvent> _disconnected = Emitter<DisconnectedEvent>();
  final Emitter<ReconnectingEvent> _reconnecting = Emitter<ReconnectingEvent>();
  final Emitter<StoppedEvent> _stopped = Emitter<StoppedEvent>();
  final Emitter<ProtocolErrorEvent> _protocolError =
      Emitter<ProtocolErrorEvent>();
  final Emitter<GatewayClientState> _stateChanges =
      Emitter<GatewayClientState>();

  GatewayClientState _state = GatewayClientState.idle;
  GatewayWebSocket? _socket;
  StreamSubscription<SocketEvent>? _subscription;
  bool _closedByUser = false;
  bool _ready = false;
  bool _socketOpened = false;
  bool _retired = false;
  int _handshakeFailures = 0;
  Timer? _helloTimer;
  Timer? _reconnectTimer;
  CloseDisposition? _closeOverride;
  Completer<void>? _pending;

  /// Current state.
  GatewayClientState get state => _state;

  /// Every state change.
  Stream<GatewayClientState> get stateChanges => _stateChanges.stream;

  /// The socket is open and the gateway echoed `bearer`.
  Stream<void> get opened => _opened.stream;

  /// Lobby: `hello` arrived (the connection is usable from here).
  Stream<Hello> get hello => _hello.stream;

  /// Every decoded frame after the connection became usable. Lobby: always
  /// a [JsonObject] with a string `type`. `q`: any JSON value.
  Stream<Object?> get frames => _frame.stream;

  /// The socket went away.
  Stream<DisconnectedEvent> get disconnected => _disconnected.stream;

  /// A retry is scheduled.
  Stream<ReconnectingEvent> get reconnecting => _reconnecting.stream;

  /// Terminal.
  Stream<StoppedEvent> get stopped => _stopped.stream;

  /// A frame that was not the protocol.
  Stream<ProtocolErrorEvent> get protocolErrors => _protocolError.stream;

  /// Opens the first socket. Completes when the connection is usable
  /// (lobby: `hello`; `q`: open); fails with [GatewayStoppedException] if
  /// it stops before that. May be called once.
  Future<void> connect() {
    if (_state != GatewayClientState.idle) {
      throw StateError('connect() called in state ${_state.name}');
    }
    final completer = Completer<void>();
    _pending = completer;
    _open();
    return completer.future;
  }

  /// Sends a frame. Throws [StateError] unless connected.
  void send(Object? frame) {
    final socket = _socket;
    if (!_ready || _retired || socket == null) {
      throw StateError('cannot send in state ${_state.name}');
    }
    socket.send(Json.encode(frame));
  }

  /// Closes for good. Idempotent.
  Future<void> close() async {
    if (_closedByUser) return;
    _closedByUser = true;
    _clearHelloTimer();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final current = _socket;
    final wasReady = _ready;
    _socket = null;
    _ready = false;
    _setState(GatewayClientState.closed);
    current?.close(1000, 'client closed');
    if (wasReady || current != null) {
      _disconnected.emit(
        const DisconnectedEvent(
          code: 1000,
          reason: 'client closed',
          willReconnect: false,
        ),
      );
    }
    _settle(
      const GatewayStoppedException(
        'closed before the connection became ready',
      ),
    );
    await _subscription?.cancel();
    _subscription = null;
    await Future.wait(<Future<void>>[
      _opened.close(),
      _hello.close(),
      _frame.close(),
      _disconnected.close(),
      _reconnecting.close(),
      _stopped.close(),
      _protocolError.close(),
      _stateChanges.close(),
    ]);
  }

  // ---- transitions -------------------------------------------------------

  void _setState(GatewayClientState next) {
    if (_state == next) return;
    _state = next;
    _stateChanges.emit(next);
  }

  void _settle([GatewayStoppedException? error]) {
    final pending = _pending;
    _pending = null;
    if (pending == null || pending.isCompleted) return;
    if (error == null) {
      pending.complete();
    } else {
      pending.completeError(error);
    }
  }

  void _clearHelloTimer() {
    _helloTimer?.cancel();
    _helloTimer = null;
  }

  void _markReady() {
    _ready = true;
    _setState(GatewayClientState.connected);
    _backoff.reset();
    // The completer's continuations run as microtasks, after the emit that
    // follows in the caller, so `await connect()` observes a client that has
    // already delivered `hello`.
    _settle();
  }

  void _stop(int code, CloseDisposition disposition) {
    _setState(GatewayClientState.closed);
    _logger.info('gateway connection stopped', <String, Object?>{
      ..._logContext,
      'code': code,
      'disposition': disposition.kind.name,
      'reason': disposition.reason,
    });
    _settle(
      GatewayStoppedException(
        'gateway connection stopped: ${disposition.reason}',
      ),
    );
    _disconnected.emit(
      DisconnectedEvent(
        code: code,
        reason: disposition.reason,
        willReconnect: false,
      ),
    );
    _stopped.emit(
      StoppedEvent(
        kind: disposition.kind,
        reason: disposition.reason,
        code: code,
      ),
    );
  }

  void _scheduleReconnect(int code, CloseDisposition disposition) {
    final delayMs = _backoff.next();
    if (delayMs == null) {
      _stop(
        code,
        const CloseDisposition(
          CloseDispositionKind.stop,
          'reconnect attempts exhausted',
        ),
      );
      return;
    }
    _setState(GatewayClientState.reconnecting);
    _disconnected.emit(
      DisconnectedEvent(
        code: code,
        reason: disposition.reason,
        willReconnect: true,
      ),
    );
    // A handler may have called close() just now.
    if (_closedByUser) return;
    _logger.info('gateway reconnecting', <String, Object?>{
      ..._logContext,
      'code': code,
      'attempt': _backoff.attempts,
      'delayMs': delayMs,
    });
    _reconnecting.emit(
      ReconnectingEvent(attempt: _backoff.attempts, delayMs: delayMs),
    );
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      _open();
    });
  }

  void _localClose(CloseDisposition disposition, String reason) {
    _closeOverride = disposition;
    // Retired: nothing this socket says after this counts, except its close.
    _retired = true;
    _socket?.close(GatewayCloseCode.local, reason);
  }

  void _open() {
    if (_closedByUser) return;
    if (_state != GatewayClientState.reconnecting) {
      _setState(GatewayClientState.connecting);
    }
    final GatewayWebSocket created;
    try {
      created = _factory.connect(
        GatewayWebSocketRequest(
          url: _url,
          subprotocols: <String>[_bearerSubprotocol, _options.token],
        ),
      );
    } catch (_) {
      // The exception may quote the URL or a subprotocol; only the fact
      // crosses into a log or an event.
      _stop(
        0,
        const CloseDisposition(
          CloseDispositionKind.stop,
          'cannot open the WebSocket',
        ),
      );
      return;
    }
    _socket = created;
    _socketOpened = false;
    _retired = false;
    _subscription = created.events.listen(
      (event) => _onEvent(created, event),
      onError: (Object _) => _onEvent(created, const SocketClosed(1006, '')),
      onDone: () {
        // A well-behaved transport already reported SocketClosed; this is
        // the backstop for one that completes without it.
        if (identical(_socket, created)) {
          _onEvent(created, const SocketClosed(1006, ''));
        }
      },
    );
  }

  void _onEvent(GatewayWebSocket source, SocketEvent event) {
    if (!identical(source, _socket)) return;
    if (_retired && event is! SocketClosed) return;
    switch (event) {
      case SocketOpened(:final protocol):
        _onOpened(protocol);
      case SocketTextMessage(:final text):
        _onText(text);
      case SocketBinaryMessage():
        _protocolError.emit(const ProtocolErrorEvent('non-text frame'));
      case SocketClosed(:final code, :final reason):
        _onClosed(code, reason);
    }
  }

  void _onOpened(String? protocol) {
    _socketOpened = true;
    _handshakeFailures = 0;
    if (protocol != _bearerSubprotocol) {
      _localClose(
        const CloseDisposition(
          CloseDispositionKind.stop,
          'gateway did not select the bearer subprotocol',
        ),
        'unexpected subprotocol',
      );
      return;
    }
    if (_options.kind == GatewayChannelKind.q) {
      // Ready before `opened`, so a handler can send the first frame.
      _markReady();
      _opened.emit(null);
      return;
    }
    _opened.emit(null);
    _helloTimer = Timer(Duration(milliseconds: _options.helloTimeoutMs), () {
      _helloTimer = null;
      _localClose(
        const CloseDisposition(CloseDispositionKind.reconnect, 'hello timeout'),
        'hello timeout',
      );
    });
  }

  void _onText(String text) {
    final Object? parsed;
    switch (Json.tryDecode(text)) {
      case JsonDecoded(:final value):
        parsed = value;
      case JsonRefused(:final failure):
        _protocolError.emit(ProtocolErrorEvent('frame is not JSON: $failure'));
        return;
    }
    if (_options.kind == GatewayChannelKind.q) {
      _frame.emit(parsed);
      return;
    }
    if (parsed is! Map<String, Object?>) {
      _protocolError.emit(const ProtocolErrorEvent('frame is not an object'));
      return;
    }
    final type = parsed.getString('type');
    if (type == null) {
      _protocolError.emit(const ProtocolErrorEvent('frame has no string type'));
      return;
    }
    if (!_ready) {
      if (type != FrameTypes.hello) {
        _protocolError.emit(
          ProtocolErrorEvent(
            'expected hello, got ${Normalize.diagnostic(type)}',
          ),
        );
        return;
      }
      _clearHelloTimer();
      _markReady();
      _hello.emit(Hello.fromJson(parsed));
      return;
    }
    _frame.emit(parsed);
  }

  void _onClosed(int code, String reason) {
    final wasRetired = _retired;
    final opened = _socketOpened;
    _socket = null;
    _subscription = null;
    _ready = false;
    _retired = false;
    _clearHelloTimer();
    if (_closedByUser) return;
    var disposition = _closeOverride ?? classifyClose(code, _options.kind);
    _closeOverride = null;
    if (!opened) {
      _handshakeFailures++;
      if (disposition.kind == CloseDispositionKind.reconnect &&
          _handshakeFailures >= _options.maxHandshakeFailures) {
        disposition = CloseDisposition(
          CloseDispositionKind.stop,
          'handshake failed $_handshakeFailures times in a row',
        );
      }
    }
    _logger.debug('gateway socket closed', <String, Object?>{
      ..._logContext,
      'code': code,
      'reasonLength': reason.length,
      'local': wasRetired,
    });
    if (disposition.kind == CloseDispositionKind.reconnect) {
      _scheduleReconnect(code, disposition);
    } else {
      _stop(code, disposition);
    }
  }
}
