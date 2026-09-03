import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'fake_web_socket.dart';

/// The fixture token: three dot-separated words that look like a JWT to a
/// human and are not one. The "never logs the token" tests search for it.
const String fixtureToken = 'eyJ.secret-token.sig';

/// The shared non-secret channel-id fixture of every yyt repo.
const String fixtureChannelId = 'lobby_0123456789abcdef';

const String fixtureGatewayUrl = 'wss://gw.example';

/// Captures formatted lines.
final class CapturingLogWriter implements LogWriter {
  final List<String> lines = <String>[];
  void _add(LogSeverity s, String m, JsonObject? c) =>
      lines.add(LogWriters.format(s, m, c));
  @override
  void debug(String message, [JsonObject? context]) =>
      _add(LogSeverity.debug, message, context);
  @override
  void info(String message, [JsonObject? context]) =>
      _add(LogSeverity.info, message, context);
  @override
  void warn(String message, [JsonObject? context]) =>
      _add(LogSeverity.warn, message, context);
  @override
  void error(String message, [JsonObject? context]) =>
      _add(LogSeverity.error, message, context);
}

JsonObject helloFrame({
  String userId = 'me',
  String zone = 'Zone001',
  String? partyId,
  JsonObject? capabilities,
  String mapUrl = 'https://d.example/map.json',
  JsonObject? aoi,
}) => <String, Object?>{
  'type': 'hello',
  'userId': userId,
  'connectionId': 'c1',
  'tick': 200,
  'mapUrl': mapUrl,
  'zone': zone,
  'partyId': ?partyId,
  'capabilities':
      capabilities ??
      <String, Object?>{
        'pos': true,
        'say': <Object?>['zone', 'party', 'user'],
        'party': true,
        'event': true,
        'debug': false,
      },
  'aoi': aoi ?? <String, Object?>{'maxPeers': 64},
};

/// Drives a lobby client with fake sockets inside `fakeAsync`.
final class LobbyHarness {
  LobbyHarness(
    this.async, {
    BackoffOptions? backoff,
    int? maxHandshakeFailures,
    int? helloTimeoutMs,
    MapHttpFetcher? httpFetcher,
    String token = fixtureToken,
  }) {
    client = GatewayLobbyClient(
      GatewayLobbyClientOptions(
        url: fixtureGatewayUrl,
        channelId: fixtureChannelId,
        token: token,
        webSocketFactory: factory,
        backoff: backoff ?? const BackoffOptions(random: _midpoint),
        maxHandshakeFailures: maxHandshakeFailures ?? 5,
        helloTimeoutMs: helloTimeoutMs ?? 10000,
        httpFetcher: httpFetcher,
        logger: createFilteredLogger(severity: LogSeverity.debug, writer: log),
      ),
    );
    client.connected.listen((h) => trace.add('connected:${h.userId}'));
    client.disconnected.listen(
      (e) => trace.add('disconnected:${e.code}:${e.willReconnect}'),
    );
    client.reconnecting.listen(
      (e) => trace.add('reconnecting:${e.attempt}:${e.delayMs}'),
    );
    client.stopped.listen((e) => trace.add('stopped:${e.code}:${e.kind.name}'));
    client.protocolErrors.listen(
      (e) => trace.add('protocolError:${e.message}'),
    );
    client.refused.listen((e) => trace.add('refused:${e.code}'));
    client.snapshots.listen((f) => trace.add('snapshot:${f.zone}'));
    client.peerEntered.listen((p) => trace.add('enter:${p.userId}'));
    client.peerLeft.listen((u) => trace.add('leave:$u'));
    client.peerMoved.listen(
      (ps) => trace.add('move:${ps.map((p) => p.userId).join(',')}'),
    );
    client.said.listen((f) => trace.add('say:${f.from}:${f.text}'));
    client.eventReceived.listen((f) => trace.add('event:${f.from}:${f.name}'));
    client.partyChanged.listen((f) => trace.add('party:${f.partyId}'));
    client.partyInvited.listen((f) => trace.add('invite:${f.partyId}'));
    client.partyDeclined.listen((f) => trace.add('declined:${f.userId}'));
    client.pong.listen((_) => trace.add('pong'));
    client.stateChanges.listen((s) => states.add(s));
  }

  static double _midpoint() => 0.5;

  final FakeAsync async;
  final FakeWebSocketFactory factory = FakeWebSocketFactory();
  final CapturingLogWriter log = CapturingLogWriter();
  final List<String> trace = <String>[];
  final List<GatewayClientState> states = <GatewayClientState>[];
  late final GatewayLobbyClient client;

  Future<Hello>? _pending;
  Object? connectError;

  FakeWebSocket get socket => factory.latest;

  /// Starts `connect()` and keeps its future so a failure is observed, not
  /// unhandled.
  void connect() {
    _pending = client.connect()
      ..catchError((Object e) {
        connectError = e;
        return Hello.fromJson(<String, Object?>{});
      });
    async.flushMicrotasks();
  }

  Future<Hello> get connectFuture => _pending!;

  /// Opens the latest socket and sends `hello`.
  void openAndHello({JsonObject? hello}) {
    socket.serverOpen();
    socket.serverSend(hello ?? helloFrame());
    async.flushMicrotasks();
  }

  void elapse(int ms) => async.elapse(Duration(milliseconds: ms));
}

/// Drives a game client with fake sockets inside `fakeAsync`.
final class GameHarness {
  GameHarness(
    this.async, {
    BackoffOptions? backoff,
    int? maxHandshakeFailures,
    String token = fixtureToken,
  }) {
    client = GatewayGameClient(
      GatewayGameClientOptions(
        url: fixtureGatewayUrl,
        channelId: 'q_0123456789abcdef',
        gameId: 'g_0123456789abcdef',
        token: token,
        webSocketFactory: factory,
        backoff: backoff ?? const BackoffOptions(random: _midpoint),
        maxHandshakeFailures: maxHandshakeFailures ?? 5,
        logger: createFilteredLogger(severity: LogSeverity.debug, writer: log),
      ),
    );
    client.connected.listen((_) => trace.add('connected'));
    client.frames.listen((f) => trace.add('frame:${Json.encode(f)}'));
    client.refused.listen((e) => trace.add('refused:${e.code}'));
    client.disconnected.listen(
      (e) => trace.add('disconnected:${e.code}:${e.willReconnect}'),
    );
    client.reconnecting.listen(
      (e) => trace.add('reconnecting:${e.attempt}:${e.delayMs}'),
    );
    client.aborted.listen((e) => trace.add('aborted:${e.code}'));
    client.finished.listen((e) => trace.add('finished:${e.code}'));
    client.stopped.listen((e) => trace.add('stopped:${e.code}:${e.kind.name}'));
    client.protocolErrors.listen(
      (e) => trace.add('protocolError:${e.message}'),
    );
  }

  static double _midpoint() => 0.5;

  final FakeAsync async;
  final FakeWebSocketFactory factory = FakeWebSocketFactory();
  final CapturingLogWriter log = CapturingLogWriter();
  final List<String> trace = <String>[];
  late final GatewayGameClient client;
  Object? connectError;

  FakeWebSocket get socket => factory.latest;

  void connect() {
    client.connect().catchError((Object e) => connectError = e);
    async.flushMicrotasks();
  }

  void elapse(int ms) => async.elapse(Duration(milliseconds: ms));
}
