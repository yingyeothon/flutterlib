import 'dart:async';
import 'dart:convert';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../client_events.dart';
import '../lobby_client.dart';
import '../protocol/capabilities.dart';
import '../protocol/close_codes.dart';
import '../protocol/frame_types.dart';
import '../protocol/hello.dart';
import '../protocol/lobby_frame_writer.dart';
import '../protocol/normalize.dart';
import '../protocol/peer.dart';
import '../protocol/peer_map.dart';
import '../protocol/server_frames.dart';
import 'emitter.dart';
import 'gateway_socket.dart';
import 'map_fetcher.dart';

/// The lobby client.
final class LobbyClientImpl implements GatewayLobbyClient {
  /// Creates the client and wires it to a [GatewaySocket].
  LobbyClientImpl(this._options)
    : _logger = _options.logger ?? nullLogger,
      _socket = GatewaySocket(
        GatewaySocketOptions(
          url: _options.url,
          channelId: _options.channelId,
          token: _options.token,
          kind: GatewayChannelKind.lobby,
          webSocketFactory: _options.webSocketFactory,
          backoff: _options.backoff,
          helloTimeoutMs: _options.helloTimeoutMs,
          maxHandshakeFailures: _options.maxHandshakeFailures,
          logger: _options.logger,
        ),
      ),
      _peers = PeerMap(selfUserId: '') {
    _subscriptions = <StreamSubscription<Object?>>[
      _socket.hello.listen(_onHello),
      _socket.frames.listen(_onFrame),
      _socket.disconnected.listen((event) {
        _peers.reset();
        _disconnected.emit(event);
      }),
      _socket.reconnecting.listen(_reconnecting.emit),
      _socket.stopped.listen(_stopped.emit),
      _socket.protocolErrors.listen(_protocolErrors.emit),
    ];
    party = _PartyCommands(this);
  }

  final GatewayLobbyClientOptions _options;
  final Logger _logger;
  final GatewaySocket _socket;
  late final List<StreamSubscription<Object?>> _subscriptions;
  MapFetcher? _mapFetcher;
  Hello? _hello;
  String? _partyId;
  PartyFrame? _roster;
  PeerMap _peers;

  final Emitter<Hello> _connected = Emitter<Hello>();
  final Emitter<DisconnectedEvent> _disconnected = Emitter<DisconnectedEvent>();
  final Emitter<ReconnectingEvent> _reconnecting = Emitter<ReconnectingEvent>();
  final Emitter<StoppedEvent> _stopped = Emitter<StoppedEvent>();
  final Emitter<SnapshotFrame> _snapshots = Emitter<SnapshotFrame>();
  final Emitter<Peer> _peerEntered = Emitter<Peer>();
  final Emitter<String> _peerLeft = Emitter<String>();
  final Emitter<List<Peer>> _peerMoved = Emitter<List<Peer>>();
  final Emitter<SayBroadcastFrame> _said = Emitter<SayBroadcastFrame>();
  final Emitter<EventBroadcastFrame> _eventReceived =
      Emitter<EventBroadcastFrame>();
  final Emitter<PartyFrame> _partyChanged = Emitter<PartyFrame>();
  final Emitter<PartyInviteFrame> _partyInvited = Emitter<PartyInviteFrame>();
  final Emitter<PartyDeclinedFrame> _partyDeclined =
      Emitter<PartyDeclinedFrame>();
  final Emitter<void> _pong = Emitter<void>();
  final Emitter<ErrorFrame> _refused = Emitter<ErrorFrame>();
  final Emitter<ProtocolErrorEvent> _protocolErrors =
      Emitter<ProtocolErrorEvent>();
  final Emitter<LobbyServerFrame> _frames = Emitter<LobbyServerFrame>();

  @override
  late final PartyCommands party;

  @override
  GatewayClientState get state => _socket.state;
  @override
  Stream<GatewayClientState> get stateChanges => _socket.stateChanges;
  @override
  Hello? get hello => _hello;
  @override
  Capabilities? get capabilities => _hello?.capabilities;
  @override
  String? get partyId => _partyId;
  @override
  PartyFrame? get roster => _roster;
  @override
  PeerMap get peers => _peers;

  @override
  Stream<Hello> get connected => _connected.stream;
  @override
  Stream<DisconnectedEvent> get disconnected => _disconnected.stream;
  @override
  Stream<ReconnectingEvent> get reconnecting => _reconnecting.stream;
  @override
  Stream<StoppedEvent> get stopped => _stopped.stream;
  @override
  Stream<SnapshotFrame> get snapshots => _snapshots.stream;
  @override
  Stream<Peer> get peerEntered => _peerEntered.stream;
  @override
  Stream<String> get peerLeft => _peerLeft.stream;
  @override
  Stream<List<Peer>> get peerMoved => _peerMoved.stream;
  @override
  Stream<SayBroadcastFrame> get said => _said.stream;
  @override
  Stream<EventBroadcastFrame> get eventReceived => _eventReceived.stream;
  @override
  Stream<PartyFrame> get partyChanged => _partyChanged.stream;
  @override
  Stream<PartyInviteFrame> get partyInvited => _partyInvited.stream;
  @override
  Stream<PartyDeclinedFrame> get partyDeclined => _partyDeclined.stream;
  @override
  Stream<void> get pong => _pong.stream;
  @override
  Stream<ErrorFrame> get refused => _refused.stream;
  @override
  Stream<ProtocolErrorEvent> get protocolErrors => _protocolErrors.stream;
  @override
  Stream<LobbyServerFrame> get frames => _frames.stream;

  @override
  Future<Hello> connect() => _socket.connect().then((_) => _hello!);

  @override
  Future<void> close() async {
    await _socket.close();
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await Future.wait(<Future<void>>[
      _connected.close(),
      _disconnected.close(),
      _reconnecting.close(),
      _stopped.close(),
      _snapshots.close(),
      _peerEntered.close(),
      _peerLeft.close(),
      _peerMoved.close(),
      _said.close(),
      _eventReceived.close(),
      _partyChanged.close(),
      _partyInvited.close(),
      _partyDeclined.close(),
      _pong.close(),
      _refused.close(),
      _protocolErrors.close(),
      _frames.close(),
    ]);
  }

  @override
  Future<Object?> map() {
    final hello = _hello;
    if (hello == null) throw StateError('map() needs hello first');
    final fetcher = _mapFetcher ??= MapFetcher(
      http: _options.httpFetcher,
      logger: _logger,
    );
    return fetcher.fetch(hello.mapUrl);
  }

  @override
  void pos({
    required String zone,
    required double x,
    required double y,
    String? dir,
  }) {
    _requireCapability('pos', capabilities?.pos);
    if (dir != null && isDirTooLong(dir)) {
      throw ArgumentError(
        'dir must be at most $maxDirBytes bytes (got ${utf8.encode(dir).length})',
      );
    }
    send(LobbyFrameWriter.pos(zone, x, y, dir));
  }

  @override
  void say({required SayScope scope, required String text, String? to}) {
    _requireScope(scope);
    send(LobbyFrameWriter.say(scope, text, to));
  }

  @override
  void event({
    required SayScope scope,
    required String name,
    Object? payload,
    String? to,
  }) {
    // The gateway gates `event` on the event flag only; the `say` scope list
    // applies to `say`. Checking it here refused frames the gateway delivers.
    _requireCapability('event', capabilities?.event);
    send(LobbyFrameWriter.event(scope, name, payload, to));
  }

  @override
  void ping() => send(LobbyFrameWriter.ping());

  @override
  void send(JsonObject frame) => _socket.send(frame);

  void _requireCapability(String name, bool? enabled) {
    if (enabled == false) {
      throw StateError('capability_off: $name is disabled on this channel');
    }
  }

  void _requireScope(SayScope scope) {
    final caps = capabilities;
    if (caps != null && !caps.allowsScope(scope)) {
      throw StateError('capability_off: say scope ${scope.wire} is disabled');
    }
  }

  void _onHello(Hello hello) {
    _hello = hello;
    _partyId = hello.partyId;
    // A roster from before the outage may be stale; the gateway re-sends
    // `party` after `hello` whenever it still knows the party.
    _roster = null;
    _peers = PeerMap(selfUserId: hello.userId);
    _logger.info('lobby connected', <String, Object?>{
      'channelId': _options.channelId,
      'userId': hello.userId,
      'tick': hello.tick,
      'zone': Normalize.diagnostic(hello.zone),
    });
    _connected.emit(hello);
  }

  void _onFrame(Object? raw) {
    final frame = readLobbyFrame(raw! as JsonObject);
    _frames.emit(frame);
    switch (frame) {
      case SnapshotFrame() ||
          EnterFrame() ||
          LeaveFrame() ||
          PosBroadcastFrame():
        _applyPeerFrame(frame);
      case SayBroadcastFrame():
        _said.emit(frame);
      case EventBroadcastFrame():
        _eventReceived.emit(frame);
      case PartyFrame():
        _roster = frame;
        _partyId = frame.partyId;
        _partyChanged.emit(frame);
      case PartyInviteFrame():
        _partyInvited.emit(frame);
      case PartyDeclinedFrame():
        _partyDeclined.emit(frame);
      case PongFrame():
        _pong.emit(null);
      case ErrorFrame():
        _logger.warn('gateway refused a lobby message', <String, Object?>{
          'channelId': _options.channelId,
          'code': frame.code,
        });
        _refused.emit(frame);
      case UnknownServerFrame():
        _protocolErrors.emit(
          ProtocolErrorEvent(
            'unknown frame type ${Normalize.diagnostic(frame.type)}',
          ),
        );
    }
  }

  void _applyPeerFrame(LobbyServerFrame frame) {
    if (frame is EnterFrame && frame.peer.userId.isEmpty) {
      _protocolErrors.emit(const ProtocolErrorEvent('enter without a userId'));
      return;
    }
    switch (_peers.apply(frame)) {
      case null:
        if (frame is LeaveFrame || frame is PosBroadcastFrame) {
          // A pos or leave for a peer not in view breaks the gateway's view
          // invariant; the frame is ignored for rendering and noted.
          _logger.debug('peer frame for an unknown peer', <String, Object?>{
            'channelId': _options.channelId,
            'type': frame.type,
          });
        }
        return;
      case PeerSnapshot():
        _snapshots.emit(frame as SnapshotFrame);
      case PeerEntered(:final peer):
        _peerEntered.emit(peer);
      case PeerLeft(:final userId):
        _peerLeft.emit(userId);
      case PeerMoved(:final peers):
        _peerMoved.emit(peers);
    }
  }
}

final class _PartyCommands implements PartyCommands {
  _PartyCommands(this._client);
  final LobbyClientImpl _client;

  void _guarded(JsonObject frame) {
    _client._requireCapability('party', _client.capabilities?.party);
    _client.send(frame);
  }

  @override
  void create() => _guarded(LobbyFrameWriter.partyCreate());
  @override
  void invite(String userId) => _guarded(LobbyFrameWriter.partyInvite(userId));
  @override
  void accept(String partyId) =>
      _guarded(LobbyFrameWriter.partyAccept(partyId));
  @override
  void decline(String partyId) =>
      _guarded(LobbyFrameWriter.partyDecline(partyId));
  @override
  void leave() => _guarded(LobbyFrameWriter.partyLeave());
  @override
  void list() => _guarded(LobbyFrameWriter.partyList());
}
