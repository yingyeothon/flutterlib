import 'dart:async';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../client_events.dart';
import '../game_client.dart';
import '../protocol/close_codes.dart';
import '../protocol/frame_types.dart';
import '../protocol/server_frames.dart';
import 'emitter.dart';
import 'gateway_socket.dart';

/// The `q` client.
final class GameClientImpl implements GatewayGameClient {
  /// Creates the client and wires it to a [GatewaySocket].
  GameClientImpl(this._options)
    : _logger = _options.logger ?? nullLogger,
      _socket = GatewaySocket(
        GatewaySocketOptions(
          url: _options.url,
          channelId: _options.channelId,
          gameId: _options.gameId,
          token: _options.token,
          kind: GatewayChannelKind.q,
          webSocketFactory: _options.webSocketFactory,
          backoff: _options.backoff,
          maxHandshakeFailures: _options.maxHandshakeFailures,
          logger: _options.logger,
        ),
      ) {
    _subscriptions = <StreamSubscription<Object?>>[
      _socket.opened.listen((_) {
        _logger.info('game connected', <String, Object?>{
          'channelId': _options.channelId,
          'gameId': _options.gameId,
        });
        _connected.emit(null);
      }),
      _socket.frames.listen(_onFrame),
      _socket.disconnected.listen(_disconnected.emit),
      _socket.reconnecting.listen(_reconnecting.emit),
      _socket.stopped.listen(_onStopped),
      _socket.protocolErrors.listen(_protocolErrors.emit),
    ];
  }

  final GatewayGameClientOptions _options;
  final Logger _logger;
  final GatewaySocket _socket;
  late final List<StreamSubscription<Object?>> _subscriptions;

  final Emitter<void> _connected = Emitter<void>();
  final Emitter<Object?> _frames = Emitter<Object?>();
  final Emitter<ErrorFrame> _refused = Emitter<ErrorFrame>();
  final Emitter<DisconnectedEvent> _disconnected = Emitter<DisconnectedEvent>();
  final Emitter<ReconnectingEvent> _reconnecting = Emitter<ReconnectingEvent>();
  final Emitter<GameEndedEvent> _aborted = Emitter<GameEndedEvent>();
  final Emitter<GameEndedEvent> _finished = Emitter<GameEndedEvent>();
  final Emitter<StoppedEvent> _stopped = Emitter<StoppedEvent>();
  final Emitter<ProtocolErrorEvent> _protocolErrors =
      Emitter<ProtocolErrorEvent>();

  @override
  GatewayClientState get state => _socket.state;
  @override
  Stream<GatewayClientState> get stateChanges => _socket.stateChanges;
  @override
  Stream<void> get connected => _connected.stream;
  @override
  Stream<Object?> get frames => _frames.stream;
  @override
  Stream<ErrorFrame> get refused => _refused.stream;
  @override
  Stream<DisconnectedEvent> get disconnected => _disconnected.stream;
  @override
  Stream<ReconnectingEvent> get reconnecting => _reconnecting.stream;
  @override
  Stream<GameEndedEvent> get aborted => _aborted.stream;
  @override
  Stream<GameEndedEvent> get finished => _finished.stream;
  @override
  Stream<StoppedEvent> get stopped => _stopped.stream;
  @override
  Stream<ProtocolErrorEvent> get protocolErrors => _protocolErrors.stream;

  @override
  Future<void> connect() => _socket.connect();

  @override
  Future<void> close() async {
    await _socket.close();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await Future.wait(<Future<void>>[
      _connected.close(),
      _frames.close(),
      _refused.close(),
      _disconnected.close(),
      _reconnecting.close(),
      _aborted.close(),
      _finished.close(),
      _stopped.close(),
      _protocolErrors.close(),
    ]);
  }

  @override
  void send(JsonObject frame) {
    final type = frame.getString('type');
    if (type == null) {
      throw StateError('bad_message: a game frame needs a string type');
    }
    if (reservedGameFrameTypes.contains(type)) {
      throw StateError('reserved_type: $type is set by the gateway');
    }
    _socket.send(frame);
  }

  void _onFrame(Object? raw) {
    if (raw is Map<String, Object?> &&
        raw.getString('type') == FrameTypes.error &&
        raw.getString('code') != null &&
        raw.getString('message') != null) {
      final frame = ErrorFrame(
        raw,
        code: raw.getString('code')!,
        message: raw.getString('message') ?? '',
      );
      _logger.warn('gateway refused a game message', <String, Object?>{
        'gameId': _options.gameId,
        'code': frame.code,
      });
      _refused.emit(frame);
      return;
    }
    _frames.emit(raw);
  }

  void _onStopped(StoppedEvent event) {
    switch (event.kind) {
      case CloseDispositionKind.aborted:
        _aborted.emit(GameEndedEvent(code: event.code, reason: event.reason));
      case CloseDispositionKind.finished:
        _finished.emit(GameEndedEvent(code: event.code, reason: event.reason));
      case CloseDispositionKind.stop ||
          CloseDispositionKind.clientBug ||
          CloseDispositionKind.reconnect:
        _stopped.emit(event);
    }
  }
}
