import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import 'fake_assets.dart';
import 'fake_kv.dart';
import 'fake_leaderboard.dart';
import 'fake_social.dart';

/// A `q` connection as the game-side hook sees it.
abstract interface class GameSession {
  /// The game id from the URL.
  String get gameId;

  /// The member.
  String get userId;

  /// Sends a frame to this member.
  void send(Object? frame);

  /// Sends a frame to every member of the game.
  void broadcast(Object? frame);
}

/// Called for every game frame a `q` member sends. The default echoes it
/// back as `{"type":"echo","of":<frame>}`.
typedef GameFrameHandler = void Function(GameSession session, Object? frame);

/// Knobs for a [FakeGateway].
final class FakeGatewayOptions {
  /// Creates options.
  const FakeGatewayOptions({
    this.acceptedTokens,
    this.tick = 200,
    this.capabilities = const <String, Object?>{
      'pos': true,
      'say': <Object?>['zone', 'party', 'user'],
      'party': true,
      'event': true,
      'debug': false,
    },
    this.partySizeMax = 4,
    this.defaultZone = 'Zone001',
    this.mapDocument = const <String, Object?>{
      'name': 'fake',
      'zones': <Object?>['Zone001', 'Zone002'],
    },
    this.onGameFrame,
    this.maxPeers = 64,
    this.kvCollections = const <FakeKvCollection>[],
    this.leaderboards = const <FakeLeaderboard>[],
    this.socialProfiles = const <FakeSocialProfile>[],
    this.assetBundles = const <FakeAssetBundle>[],
    this.channels,
    this.games,
    this.clock,
    this.maxMoveDelta,
  });

  /// Tokens the handshake accepts; `null` accepts any non-empty token.
  final Set<String>? acceptedTokens;

  /// `hello.tick` and the `pos` flush interval, in ms.
  final int tick;

  /// `hello.capabilities`, verbatim.
  final JsonObject capabilities;

  /// Party size cap.
  final int partySizeMax;

  /// `hello.zone`.
  final String defaultZone;

  /// What `GET /map.json` serves.
  final Object? mapDocument;

  /// Hook for `q` frames; `null` echoes.
  final GameFrameHandler? onGameFrame;

  /// `hello.aoi.maxPeers`.
  final int maxPeers;

  /// The collections `/kv/*` serves; empty means every kv route is a `404`.
  final List<FakeKvCollection> kvCollections;

  /// The boards `/lb/*` serves; empty means every lb route is a `404`.
  final List<FakeLeaderboard> leaderboards;

  /// The cards `/social/*` starts with; the graph itself starts empty.
  final List<FakeSocialProfile> socialProfiles;

  /// The bundles `/assets/{id}/…` serves; any other path there is a `403`.
  final List<FakeAssetBundle> assetBundles;

  /// Channel ids the handshake knows; any other answers `404`. `null`
  /// accepts every channel.
  final Set<String>? channels;

  /// The `q` start events: game id → member user ids. A handshake for a game
  /// not listed, or by a user not in it, answers `403` — one code for both,
  /// like the gateway. `null` accepts every game and member.
  final Map<String, Set<String>>? games;

  /// The clock the actor-death rule reads; `DateTime.now` by default.
  final DateTime Function()? clock;

  /// A `pos` inside your current zone that moves either axis further than
  /// this is refused with `move_too_far`, measured from where the fake has
  /// you — a retained position included. `null` (the default) checks
  /// nothing; the gateway's own default is 3.
  final double? maxMoveDelta;
}

/// The fake gateway. Start one with [FakeGateway.start].
abstract interface class FakeGateway {
  /// Binds a loopback server. [port] `0` picks a free one.
  static Future<FakeGateway> start({
    int port = 0,
    FakeGatewayOptions options = const FakeGatewayOptions(),
  }) => _FakeGateway.start(port, options);

  /// The gateway origin for `GatewayClientOptions.url`, `ws://127.0.0.1:port`.
  Uri get wsUrl;

  /// Where the map document is served.
  Uri get mapUrl;

  /// The origin for `KvStoreClientOptions.baseUrl`, `http://127.0.0.1:port`;
  /// the same listener serves `/kv/*`.
  Uri get kvUrl;

  /// The in-memory store behind `/kv/*`, to read what a client wrote.
  FakeKvStore get kv;

  /// The in-memory boards behind `/lb/*`, on the same origin as [kvUrl].
  FakeLeaderboardStore get lb;

  /// The in-memory cards and relations behind `/social/*`, same origin.
  FakeSocialStore get social;

  /// `http://127.0.0.1:port/assets/`; a bundle's base URL for
  /// `AssetBundleClientOptions.baseUrl` is this plus its id and a `/`.
  Uri get assetsUrl;

  /// The bound port.
  int get port;

  /// User ids with a live lobby socket.
  Set<String> get lobbyUsers;

  /// User ids with a live `q` socket, per game id.
  Map<String, Set<String>> get gameMembers;

  /// Every lobby frame received from [userId], decoded, in order.
  List<JsonObject> received(String userId);

  /// Closes [userId]'s lobby socket (or, with [gameId], their `q` socket)
  /// with [code], as the gateway would.
  Future<void> closeUser(
    String userId,
    int code, {
    String reason = '',
    String? gameId,
  });

  /// Sends raw text to [userId]'s lobby socket, to inject a protocol
  /// violation.
  void sendRaw(String userId, String text);

  /// Sends a binary frame to [userId]'s lobby socket.
  void sendBinary(String userId, List<int> bytes);

  /// Refuses the next [count] handshakes with [status] before any other
  /// check, for the answers a fake cannot earn on its own: `410` (channel
  /// expired), `429` (handshake burst), `502` and `503`.
  void refuseHandshakes(int status, {int count = 1});

  /// [gameId]'s actor stops consuming: every push (an `enter`, a game frame)
  /// deepens its queue instead of reaching [FakeGatewayOptions.onGameFrame],
  /// and the gateway's death rule applies — depth over 200, or over 20 for
  /// more than 5 s, closes every member with `4001` and forgets the game.
  void stallGame(String gameId);

  /// Holds [userId]'s lobby frames as a reader that stopped draining would:
  /// they wait in the 256-frame outbound queue, a full queue drops its
  /// oldest `pos` batch, and a queue of nothing but control frames closes the
  /// socket with `4005`.
  void holdOutbound(String userId);

  /// Delivers what [holdOutbound] kept, in order, and stops holding.
  void releaseOutbound(String userId);

  /// Closes every socket and the listener.
  Future<void> shutdown();
}

/// Adds to a socket that may have closed under us (a peer's disconnect
/// fans out while the listener is shutting down). A closed sink is not an
/// error the fake needs to surface.
void _safeAdd(WebSocket socket, Object data) {
  if (socket.readyState != WebSocket.open) return;
  try {
    socket.add(data);
  } on StateError {
    // Closed between the check and the add.
  }
}

/// The gateway's outbound frame cap, in bytes.
const int _maxOutboundBytes = 32 << 10;

/// The gateway's per-socket outbound queue depth.
const int _outboundQueueDepth = 256;

/// What the gateway sends in place of a frame over [_maxOutboundBytes].
String _frameTooLarge(int bytes) => Json.encode(<String, Object?>{
  'type': 'error',
  'code': 'frame_too_large',
  'message':
      'a $bytes-byte frame exceeded the $_maxOutboundBytes-byte outbound '
      'cap and was dropped',
});

/// [text] if it fits the outbound cap, else the refusal that replaces it.
String _capped(String text) {
  final bytes = utf8.encode(text).length;
  return bytes > _maxOutboundBytes ? _frameTooLarge(bytes) : text;
}

final class _Peer {
  _Peer(this.userId);
  final String userId;
  String? zone;
  double x = 0;
  double y = 0;
  String? dir;
  bool moved = false;

  JsonObject toJson() => Json.object()
      .set('userId', userId)
      .set('x', x)
      .set('y', y)
      .set('dir', dir)
      .build();
}

final class _Party {
  _Party(this.id, this.leaderId);
  final String id;
  String leaderId;
  final List<String> members = <String>[];
  final List<String> invited = <String>[];
}

final class _LobbyConnection {
  _LobbyConnection(this.userId, this.socket);
  final String userId;
  final WebSocket socket;

  /// Frames kept by [FakeGateway.holdOutbound]; `null` delivers at once.
  List<({String text, bool droppable})>? held;

  /// Closed with `4005`: the backlog is gone and nothing more is sent.
  bool tooSlow = false;
}

/// A `q` game's actor queue, as far as the death rule needs it.
final class _Actor {
  bool stalled = false;
  int depth = 0;
  DateTime? lastHealthy;
}

final class _GameConnection implements GameSession {
  _GameConnection(this.gateway, this.gameId, this.userId, this.socket);
  final _FakeGateway gateway;
  @override
  final String gameId;
  @override
  final String userId;
  final WebSocket socket;

  @override
  void send(Object? frame) => _safeAdd(socket, _capped(Json.encode(frame)));

  @override
  void broadcast(Object? frame) {
    final text = _capped(Json.encode(frame));
    for (final c in gateway._games[gameId]?.values ?? <_GameConnection>[]) {
      _safeAdd(c.socket, text);
    }
  }
}

final class _FakeGateway implements FakeGateway {
  _FakeGateway(this._server, this._options)
    : kv = FakeKvStore(
        _options.kvCollections,
        userIdOf: _userIdOf,
        acceptedTokens: _options.acceptedTokens,
      ),
      lb = FakeLeaderboardStore(
        _options.leaderboards,
        userIdOf: _userIdOf,
        acceptedTokens: _options.acceptedTokens,
        clock: _options.clock,
      ),
      social = FakeSocialStore(
        _options.socialProfiles,
        userIdOf: _userIdOf,
        acceptedTokens: _options.acceptedTokens,
        clock: _options.clock,
      ),
      _assets = FakeAssetStore(_options.assetBundles) {
    _flush = Timer.periodic(
      Duration(milliseconds: _options.tick),
      (_) => _flushPositions(),
    );
  }

  static Future<FakeGateway> start(int port, FakeGatewayOptions options) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final gateway = _FakeGateway(server, options);
    server.listen(gateway._handle);
    return gateway;
  }

  final HttpServer _server;
  final FakeGatewayOptions _options;
  @override
  final FakeKvStore kv;
  @override
  final FakeLeaderboardStore lb;
  @override
  final FakeSocialStore social;
  final FakeAssetStore _assets;
  late final Timer _flush;
  final Map<String, _LobbyConnection> _lobby = <String, _LobbyConnection>{};
  final Map<String, _Peer> _peers = <String, _Peer>{};
  final Map<String, _Party> _parties = <String, _Party>{};
  final Map<String, String> _partyOf = <String, String>{};
  final Map<String, List<JsonObject>> _received = <String, List<JsonObject>>{};
  final Map<String, Map<String, _GameConnection>> _games =
      <String, Map<String, _GameConnection>>{};
  final Map<String, _Actor> _actors = <String, _Actor>{};
  int _partySeq = 0;
  int _refuseStatus = 0;
  int _refuseCount = 0;

  DateTime _now() => (_options.clock ?? DateTime.now)();

  @override
  int get port => _server.port;
  @override
  Uri get wsUrl => Uri.parse('ws://127.0.0.1:$port');
  @override
  Uri get mapUrl => Uri.parse('http://127.0.0.1:$port/map.json');
  @override
  Uri get kvUrl => Uri.parse('http://127.0.0.1:$port');
  @override
  Uri get assetsUrl => Uri.parse('http://127.0.0.1:$port/assets/');
  @override
  Set<String> get lobbyUsers => _lobby.keys.toSet();
  @override
  Map<String, Set<String>> get gameMembers => <String, Set<String>>{
    for (final e in _games.entries) e.key: e.value.keys.toSet(),
  };

  @override
  List<JsonObject> received(String userId) =>
      List<JsonObject>.unmodifiable(_received[userId] ?? const <JsonObject>[]);

  @override
  Future<void> closeUser(
    String userId,
    int code, {
    String reason = '',
    String? gameId,
  }) async {
    if (gameId != null) {
      final c = _games[gameId]?[userId];
      if (c != null) await c.socket.close(code, reason);
      return;
    }
    final c = _lobby[userId];
    if (c != null) await c.socket.close(code, reason);
  }

  @override
  void sendRaw(String userId, String text) {
    final c = _lobby[userId];
    if (c != null) _safeAdd(c.socket, text);
  }

  @override
  void sendBinary(String userId, List<int> bytes) {
    final c = _lobby[userId];
    if (c != null) _safeAdd(c.socket, bytes);
  }

  @override
  void refuseHandshakes(int status, {int count = 1}) {
    _refuseStatus = status;
    _refuseCount = count;
  }

  @override
  void stallGame(String gameId) =>
      _actors.putIfAbsent(gameId, _Actor.new).stalled = true;

  @override
  void holdOutbound(String userId) {
    final c = _lobby[userId];
    if (c != null) c.held ??= <({String text, bool droppable})>[];
  }

  @override
  void releaseOutbound(String userId) {
    final c = _lobby[userId];
    final held = c?.held;
    if (c == null || held == null) return;
    c.held = null;
    for (final q in held) {
      _safeAdd(c.socket, q.text);
    }
  }

  @override
  Future<void> shutdown() async {
    _flush.cancel();
    for (final c in _lobby.values.toList()) {
      await c.socket.close(1001, 'gateway restarting');
    }
    for (final game in _games.values.toList()) {
      for (final c in game.values.toList()) {
        await c.socket.close(1001, 'gateway restarting');
      }
    }
    await _server.close(force: true);
  }

  // ---- HTTP ----------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path == '/map.json') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(Json.encode(_options.mapDocument));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/livez') {
        request.response.write('ok');
        await request.response.close();
        return;
      }
      if (FakeKvStore.handles(request.uri.path)) {
        await kv.handle(request);
        return;
      }
      if (FakeLeaderboardStore.handles(request.uri.path)) {
        await lb.handle(request);
        return;
      }
      if (FakeSocialStore.handles(request.uri.path)) {
        await social.handle(request);
        return;
      }
      if (FakeAssetStore.handles(request.uri.path)) {
        await _assets.handle(request);
        return;
      }
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        await _reject(request, HttpStatus.notFound);
        return;
      }
      if (_refuseCount > 0) {
        _refuseCount--;
        await _reject(request, _refuseStatus);
        return;
      }
      final channel = request.uri.queryParameters['channel'];
      if (channel == null || channel.isEmpty) {
        await _reject(request, HttpStatus.badRequest);
        return;
      }
      // The gateway's order: a missing bearer (401), then the channel
      // lookup (404), then the token itself (401), then `q` membership (403).
      final protocols = _subprotocols(request);
      final bearerAt = protocols.indexOf('bearer');
      if (bearerAt < 0 || bearerAt + 1 >= protocols.length) {
        await _reject(request, HttpStatus.unauthorized);
        return;
      }
      final channels = _options.channels;
      if (channels != null && !channels.contains(channel)) {
        await _reject(request, HttpStatus.notFound);
        return;
      }
      final token = protocols[bearerAt + 1];
      final accepted = _options.acceptedTokens;
      if (token.isEmpty || (accepted != null && !accepted.contains(token))) {
        await _reject(request, HttpStatus.unauthorized);
        return;
      }
      final userId = _userIdOf(token);
      // Like the gateway: `gameId`, or when it is absent or empty `x-game-id`.
      final query = request.uri.queryParameters;
      final named = query['gameId'];
      final gameId = named != null && named.isNotEmpty
          ? named
          : query['x-game-id'];
      final games = _options.games;
      if (gameId != null &&
          games != null &&
          !(games[gameId]?.contains(userId) ?? false)) {
        await _reject(request, HttpStatus.forbidden);
        return;
      }
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (_) => 'bearer',
      );
      if (gameId != null) {
        _attachGame(gameId, userId, socket);
      } else {
        _attachLobby(userId, socket);
      }
    } catch (_) {
      // A client that vanished mid-handshake; nothing to do.
    }
  }

  static Future<void> _reject(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }

  static List<String> _subprotocols(HttpRequest request) {
    final values =
        request.headers['sec-websocket-protocol'] ?? const <String>[];
    return values
        .expand((v) => v.split(','))
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
  }

  /// A JWT's `sub`, or the token text itself.
  static String _userIdOf(String token) {
    final parts = token.split('.');
    if (parts.length == 3) {
      try {
        final payload = utf8.decode(
          base64Url.decode(base64Url.normalize(parts[1])),
        );
        final decoded = Json.tryDecode(payload);
        if (decoded is JsonDecoded && decoded.value is Map<String, Object?>) {
          final sub = (decoded.value! as Map<String, Object?>).getString('sub');
          if (sub != null && sub.isNotEmpty) return sub;
        }
      } on FormatException {
        // Not a JWT; fall through.
      }
    }
    return token;
  }

  // ---- q -------------------------------------------------------------------

  void _attachGame(String gameId, String userId, WebSocket socket) {
    final game = _games.putIfAbsent(gameId, () {
      // A new game object starts healthy, as the gateway's does; the queue
      // (and its depth) outlives it.
      _actors[gameId]?.lastHealthy = _now();
      return <String, _GameConnection>{};
    });
    final previous = game[userId];
    if (previous != null) {
      unawaited(previous.socket.close(4000, 'replaced'));
    }
    final connection = _GameConnection(this, gameId, userId, socket);
    game[userId] = connection;
    socket.listen(
      (data) {
        if (data is! String) {
          unawaited(socket.close(1003, 'text only'));
          return;
        }
        if (utf8.encode(data).length > 16 * 1024) {
          unawaited(socket.close(1009, 'frame too large'));
          return;
        }
        final decoded = Json.tryDecode(data);
        final value = decoded is JsonDecoded ? decoded.value : null;
        if (decoded is! JsonDecoded ||
            value is! Map<String, Object?> ||
            value.getString('type') == null) {
          connection.send(
            _error('bad_message', 'frame must be an object with a string type'),
          );
          return;
        }
        final type = value.getString('type')!;
        if (type == 'enter' || type == 'leave') {
          connection.send(
            _error('reserved_type', '$type is set by the gateway'),
          );
          return;
        }
        // A frame from a socket whose game was killed (or replaced) never
        // reaches a successor under the same id.
        if (!identical(_games[gameId], game) ||
            !identical(game[userId], connection)) {
          return;
        }
        if (!_push(gameId)) return;
        final handler = _options.onGameFrame;
        if (handler != null) {
          handler(connection, value);
        } else {
          connection.send(<String, Object?>{'type': 'echo', 'of': value});
        }
      },
      onDone: () {
        // A game the death rule removed is not this one's to touch: a new
        // socket may already have started another under the same id.
        if (!identical(_games[gameId], game)) return;
        if (identical(game[userId], connection)) {
          game.remove(userId);
          // The `leave` push counts toward the depth, and may kill the game.
          _push(gameId);
          if (identical(_games[gameId], game) && game.isEmpty) {
            _games.remove(gameId);
          }
        }
      },
      onError: (Object _) {},
    );
    // The `enter` push; a stalled actor never answers it.
    if (!_push(gameId)) return;
    connection.send(<String, Object?>{
      'type': 'welcome',
      'gameId': gameId,
      'userId': userId,
      'members': game.keys.toList(),
    });
  }

  /// One push onto [gameId]'s actor queue. `false` when the actor is stalled
  /// (nothing reaches the game) or the push just killed the game.
  bool _push(String gameId) {
    final actor = _actors[gameId];
    if (actor == null || !actor.stalled) return true;
    final now = _now();
    actor.depth++;
    // Every queue passes through depth 1..20 first, so this is always set
    // before the rule below reads it.
    if (actor.depth <= 20) actor.lastHealthy = now;
    final dead =
        actor.depth > 200 ||
        (actor.depth > 20 &&
            now.difference(actor.lastHealthy!) > const Duration(seconds: 5));
    if (dead) {
      // The queue is deleted; the actor stays stalled, so a game started
      // again under this id dies the same way.
      actor
        ..depth = 0
        ..lastHealthy = null;
      final members = _games.remove(gameId)?.values.toList() ?? const [];
      for (final c in members) {
        unawaited(c.socket.close(4001, 'actor-unavailable'));
      }
    }
    return false;
  }

  // ---- lobby ---------------------------------------------------------------

  void _attachLobby(String userId, WebSocket socket) {
    final previous = _lobby[userId];
    if (previous != null) {
      unawaited(previous.socket.close(4000, 'replaced'));
      _lobby.remove(userId);
      _leaveView(userId, previous);
    }
    final connection = _LobbyConnection(userId, socket);
    _lobby[userId] = connection;
    final peer = _peers.putIfAbsent(userId, () => _Peer(userId));
    socket.listen(
      (data) => _onLobbyData(connection, data),
      onDone: () {
        if (identical(_lobby[userId], connection)) {
          _lobby.remove(userId);
          _leaveView(userId, connection);
        }
      },
      onError: (Object _) {},
    );
    final partyId = _partyOf[userId];
    _send(
      connection,
      Json.object()
          .set('type', 'hello')
          .set('userId', userId)
          .set('connectionId', 'fake:${socket.hashCode}')
          .set('tick', _options.tick)
          .set('mapUrl', mapUrl.toString())
          .set('zone', _options.defaultZone)
          .set('partyId', partyId)
          .set('capabilities', _options.capabilities)
          .set('aoi', <String, Object?>{'maxPeers': _options.maxPeers})
          .build(),
    );
    // Like the gateway: the retained position first (only with `pos` on),
    // then the roster.
    if (peer.zone != null && _capability('pos')) {
      _enterZone(connection, peer, peer.zone!, announce: true);
    }
    if (partyId != null) {
      _broadcastRoster(_parties[partyId]!);
    }
  }

  void _onLobbyData(_LobbyConnection c, Object? data) {
    if (data is! String) {
      unawaited(c.socket.close(1003, 'text only'));
      return;
    }
    if (utf8.encode(data).length > 16 * 1024) {
      unawaited(c.socket.close(1009, 'frame too large'));
      return;
    }
    final decoded = Json.tryDecode(data);
    final value = decoded is JsonDecoded ? decoded.value : null;
    if (value is! Map<String, Object?> || value.getString('type') == null) {
      _send(
        c,
        _error('bad_message', 'frame must be an object with a string type'),
      );
      return;
    }
    _received.putIfAbsent(c.userId, () => <JsonObject>[]).add(value);
    switch (value.getString('type')) {
      case 'pos':
        _onPos(c, value);
      case 'say':
        _onSayOrEvent(c, value, isEvent: false);
      case 'event':
        _onSayOrEvent(c, value, isEvent: true);
      case 'party.create' ||
              'party.invite' ||
              'party.accept' ||
              'party.decline' ||
              'party.leave' ||
              'party.list'
          when !_capability('party'):
        _send(c, _error('capability_off', 'party is off'));
      case 'party.create':
        _onPartyCreate(c);
      case 'party.invite':
        _onPartyInvite(c, value.getString('userId') ?? '');
      case 'party.accept':
        _onPartyAccept(c, value.getString('partyId') ?? '', accept: true);
      case 'party.decline':
        _onPartyAccept(c, value.getString('partyId') ?? '', accept: false);
      case 'party.leave':
        _onPartyLeave(c);
      case 'party.list':
        _onPartyList(c);
      case 'ping':
        _send(c, <String, Object?>{'type': 'pong'});
      default:
        _send(c, _error('bad_message', 'unknown type'));
    }
  }

  bool _capability(String name) => _options.capabilities.getBool(name) != false;

  void _onPos(_LobbyConnection c, JsonObject frame) {
    if (!_capability('pos')) {
      _send(c, _error('capability_off', 'pos is off'));
      return;
    }
    final zone = frame.getString('zone');
    final x = frame.getDouble('x');
    final y = frame.getDouble('y');
    if (x == null || y == null || !x.isFinite || !y.isFinite) {
      _send(c, _error('bad_message', 'x and y must be numbers'));
      return;
    }
    if (zone == null || zone.isEmpty) {
      _send(c, _error('bad_zone', 'zone is required'));
      return;
    }
    final dirRaw = frame['dir'];
    if (dirRaw != null &&
        (dirRaw is! String || utf8.encode(dirRaw).length > 16)) {
      _send(
        c,
        _error('bad_message', 'dir must be a string of at most 16 bytes'),
      );
      return;
    }
    final peer = _peers[c.userId]!;
    final delta = _options.maxMoveDelta;
    if (delta != null &&
        peer.zone == zone &&
        ((x - peer.x).abs() > delta || (y - peer.y).abs() > delta)) {
      _send(c, _error('move_too_far', 'movement exceeds maxMoveDelta'));
      return;
    }
    peer
      ..x = x
      ..y = y
      ..dir = dirRaw as String?;
    if (peer.zone != zone) {
      _enterZone(c, peer, zone, announce: true);
    } else {
      peer.moved = true;
    }
  }

  void _enterZone(
    _LobbyConnection c,
    _Peer peer,
    String zone, {
    required bool announce,
  }) {
    if (peer.zone != null && peer.zone != zone) {
      _broadcastZone(peer.zone!, <String, Object?>{
        'type': 'leave',
        'zone': peer.zone,
        'userId': peer.userId,
      }, except: peer.userId);
    }
    peer.zone = zone;
    // Like the gateway's markDirty on entry: the next flush carries the
    // entrant's position to the zone, the entrant included — which is how a
    // client learns where a retained position put it.
    peer.moved = true;
    final inView = _viewOf(peer).map((p) => p.toJson()).toList();
    _send(c, <String, Object?>{
      'type': 'snapshot',
      'zone': zone,
      'peers': inView,
    });
    if (announce) {
      _broadcastZone(zone, <String, Object?>{
        'type': 'enter',
        'zone': zone,
        ...peer.toJson(),
      }, except: peer.userId);
    }
  }

  void _leaveView(String userId, _LobbyConnection connection) {
    final peer = _peers[userId];
    if (peer?.zone == null) return;
    _broadcastZone(peer!.zone!, <String, Object?>{
      'type': 'leave',
      'zone': peer.zone,
      'userId': userId,
    }, except: userId);
    // The position is retained for a reconnect (the zone stays set).
  }

  /// What `snapshot` shows [self]: the other live peers of its zone, the
  /// `maxPeers` nearest (Chebyshev distance, then user id), by user id.
  /// Later `enter`/`pos` frames are zone-wide: the fake has no view tracking.
  List<_Peer> _viewOf(_Peer self) {
    double dist(_Peer o) {
      final dx = (o.x - self.x).abs();
      final dy = (o.y - self.y).abs();
      return dx > dy ? dx : dy;
    }

    final view =
        _lobby.keys
            .map((u) => _peers[u]!)
            .where((p) => p.zone == self.zone && p.userId != self.userId)
            .toList()
          ..sort((a, b) {
            final d = dist(a).compareTo(dist(b));
            return d != 0 ? d : a.userId.compareTo(b.userId);
          });
    return (view.take(_options.maxPeers).toList()
      ..sort((a, b) => a.userId.compareTo(b.userId)));
  }

  void _flushPositions() {
    final byZone = <String, List<JsonObject>>{};
    for (final peer in _peers.values) {
      if (!peer.moved ||
          peer.zone == null ||
          !_lobby.containsKey(peer.userId)) {
        continue;
      }
      peer.moved = false;
      byZone.putIfAbsent(peer.zone!, () => <JsonObject>[]).add(peer.toJson());
    }
    for (final e in byZone.entries) {
      _broadcastZone(e.key, <String, Object?>{
        'type': 'pos',
        'zone': e.key,
        'peers': e.value,
      });
    }
  }

  void _onSayOrEvent(
    _LobbyConnection c,
    JsonObject frame, {
    required bool isEvent,
  }) {
    if (isEvent && !_capability('event')) {
      _send(c, _error('capability_off', 'event is off'));
      return;
    }
    final scope = frame.getString('scope');
    if (scope == null ||
        !const <String>['zone', 'party', 'user'].contains(scope)) {
      _send(c, _error('bad_scope', 'unknown scope'));
      return;
    }
    // Like the gateway: the say-scope list gates `say` only; `event` is
    // gated by the event flag alone.
    final allowed = _options.capabilities['say'];
    final sayAllowed = allowed is List<Object?> && allowed.contains(scope);
    if (!isEvent && !sayAllowed) {
      _send(c, _error('capability_off', 'scope is off'));
      return;
    }
    final text = frame.getString('text') ?? '';
    final name = frame.getString('name') ?? '';
    if (!isEvent && (text.isEmpty || utf8.encode(text).length > 1024)) {
      _send(c, _error('too_long', 'text must be 1..1024 bytes'));
      return;
    }
    if (isEvent && (name.isEmpty || utf8.encode(name).length > 64)) {
      _send(c, _error('bad_message', 'name must be 1..64 bytes'));
      return;
    }
    // The gateway measures the raw payload bytes; re-encoding is as close as
    // a decoded frame gets.
    if (isEvent &&
        frame.containsKey('payload') &&
        utf8.encode(Json.encode(frame['payload'])).length > 8 << 10) {
      _send(c, _error('too_long', 'payload over 8 KB'));
      return;
    }
    final out = Json.object()
        .set('type', isEvent ? 'event' : 'say')
        .set('from', c.userId)
        .set('scope', scope)
        .set('to', scope == 'user' ? frame.getString('to') : null)
        .set(isEvent ? 'name' : 'text', isEvent ? name : text)
        .set('payload', isEvent ? frame['payload'] : null)
        .build();
    switch (scope) {
      case 'zone':
        final zone = _peers[c.userId]!.zone;
        if (zone == null) {
          _send(c, _error('bad_zone', 'announce a position first'));
          return;
        }
        _broadcastZone(zone, out);
      case 'party':
        final partyId = _partyOf[c.userId];
        if (partyId == null) {
          _send(c, _error('no_party', 'not in a party'));
          return;
        }
        for (final m in _parties[partyId]!.members) {
          _sendTo(m, out);
        }
      case 'user':
        final to = frame.getString('to');
        if (to == null || !_lobby.containsKey(to)) {
          _send(c, _error('unknown_user', 'not online'));
          return;
        }
        _sendTo(to, out);
        if (to != c.userId) _send(c, out);
    }
  }

  // ---- parties -------------------------------------------------------------

  void _onPartyCreate(_LobbyConnection c) {
    if (_partyOf.containsKey(c.userId)) {
      _send(c, _error('already_in_party', 'leave first'));
      return;
    }
    final party = _Party('pty_${++_partySeq}', c.userId)..members.add(c.userId);
    _parties[party.id] = party;
    _partyOf[c.userId] = party.id;
    _broadcastRoster(party);
  }

  void _onPartyInvite(_LobbyConnection c, String userId) {
    final party = _partyOfUser(c);
    if (party == null) return;
    if (party.leaderId != c.userId) {
      _send(c, _error('not_leader', 'only the leader invites'));
      return;
    }
    if (!_lobby.containsKey(userId)) {
      _send(c, _error('unknown_user', 'not online'));
      return;
    }
    if (_partyOf.containsKey(userId)) {
      _send(c, _error('already_in_party', 'already in a party'));
      return;
    }
    if (party.members.length + party.invited.length >= _options.partySizeMax) {
      _send(c, _error('party_full', 'party is full'));
      return;
    }
    if (!party.invited.contains(userId)) {
      party.invited.add(userId);
      _sendTo(userId, <String, Object?>{
        'type': 'party.invite',
        'partyId': party.id,
        'from': c.userId,
      });
      _broadcastRoster(party);
    }
  }

  void _onPartyAccept(
    _LobbyConnection c,
    String partyId, {
    required bool accept,
  }) {
    final party = _parties[partyId];
    if (party == null) {
      _send(c, _error('unknown_party', 'no such party'));
      return;
    }
    if (!party.invited.contains(c.userId)) {
      _send(c, _error('not_invited', 'no invite'));
      return;
    }
    party.invited.remove(c.userId);
    if (!accept) {
      _sendTo(party.leaderId, <String, Object?>{
        'type': 'party.declined',
        'partyId': party.id,
        'userId': c.userId,
      });
      _broadcastRoster(party);
      return;
    }
    if (party.members.length >= _options.partySizeMax) {
      _send(c, _error('party_full', 'party is full'));
      return;
    }
    party.members.add(c.userId);
    _partyOf[c.userId] = party.id;
    _broadcastRoster(party);
  }

  void _onPartyLeave(_LobbyConnection c) {
    final party = _partyOfUser(c);
    if (party == null) return;
    party.members.remove(c.userId);
    _partyOf.remove(c.userId);
    _send(c, <String, Object?>{
      'type': 'party',
      'partyId': '',
      'members': <Object?>[],
    });
    if (party.members.isEmpty) {
      _parties.remove(party.id);
      return;
    }
    if (party.leaderId == c.userId) party.leaderId = party.members.first;
    _broadcastRoster(party);
  }

  void _onPartyList(_LobbyConnection c) {
    final party = _partyOfUser(c, silent: true);
    if (party == null) {
      _send(c, <String, Object?>{
        'type': 'party',
        'partyId': '',
        'members': <Object?>[],
      });
      return;
    }
    _send(c, _rosterFrame(party));
  }

  _Party? _partyOfUser(_LobbyConnection c, {bool silent = false}) {
    final id = _partyOf[c.userId];
    if (id == null) {
      if (!silent) _send(c, _error('no_party', 'not in a party'));
      return null;
    }
    return _parties[id];
  }

  /// Go `omitempty`: `leaderId`, `invited` and `max` are absent when empty.
  JsonObject _rosterFrame(_Party party) => Json.object()
      .set('type', 'party')
      .set('partyId', party.id)
      .set('leaderId', party.leaderId.isEmpty ? null : party.leaderId)
      .set('members', <Object?>[
        for (final m in party.members)
          <String, Object?>{'userId': m, 'online': _lobby.containsKey(m)},
      ])
      .set(
        'invited',
        party.invited.isEmpty ? null : List<Object?>.of(party.invited),
      )
      .set('max', _options.partySizeMax == 0 ? null : _options.partySizeMax)
      .build();

  void _broadcastRoster(_Party party) {
    final frame = _rosterFrame(party);
    for (final m in party.members) {
      _sendTo(m, frame);
    }
  }

  // ---- plumbing ------------------------------------------------------------

  static JsonObject _error(String code, String message) => <String, Object?>{
    'type': 'error',
    'code': code,
    'message': message,
  };

  void _send(_LobbyConnection c, JsonObject frame) =>
      _deliver(c, Json.encode(frame), droppable: false);

  /// Every lobby frame leaves through here: the 32 KB cap, then the held
  /// queue of [holdOutbound] with the gateway's drop policy — only a `pos`
  /// batch is droppable.
  void _deliver(_LobbyConnection c, String text, {required bool droppable}) {
    final bytes = utf8.encode(text).length;
    if (bytes > _maxOutboundBytes) {
      text = _frameTooLarge(bytes);
      droppable = false;
    }
    if (c.tooSlow) return;
    final held = c.held;
    if (held == null) {
      _safeAdd(c.socket, text);
      return;
    }
    if (held.length >= _outboundQueueDepth) {
      final oldest = held.indexWhere((q) => q.droppable);
      if (oldest < 0) {
        c
          ..held = null
          ..tooSlow = true;
        unawaited(c.socket.close(4005, 'too_slow'));
        return;
      }
      held.removeAt(oldest);
    }
    held.add((text: text, droppable: droppable));
  }

  void _sendTo(String userId, JsonObject frame) {
    final c = _lobby[userId];
    if (c != null) _send(c, frame);
  }

  void _broadcastZone(String zone, JsonObject frame, {String? except}) {
    final text = Json.encode(frame);
    final droppable = frame['type'] == 'pos';
    for (final c in _lobby.values.toList()) {
      if (c.userId == except) continue;
      if (_peers[c.userId]?.zone != zone) continue;
      _deliver(c, text, droppable: droppable);
    }
  }
}
