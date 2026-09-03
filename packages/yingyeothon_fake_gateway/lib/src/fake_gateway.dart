import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

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
  void send(Object? frame) => _safeAdd(socket, Json.encode(frame));

  @override
  void broadcast(Object? frame) {
    final text = Json.encode(frame);
    for (final c in gateway._games[gameId]?.values ?? <_GameConnection>[]) {
      _safeAdd(c.socket, text);
    }
  }
}

final class _FakeGateway implements FakeGateway {
  _FakeGateway(this._server, this._options) {
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
  late final Timer _flush;
  final Map<String, _LobbyConnection> _lobby = <String, _LobbyConnection>{};
  final Map<String, _Peer> _peers = <String, _Peer>{};
  final Map<String, _Party> _parties = <String, _Party>{};
  final Map<String, String> _partyOf = <String, String>{};
  final Map<String, List<JsonObject>> _received = <String, List<JsonObject>>{};
  final Map<String, Map<String, _GameConnection>> _games =
      <String, Map<String, _GameConnection>>{};
  int _partySeq = 0;

  @override
  int get port => _server.port;
  @override
  Uri get wsUrl => Uri.parse('ws://127.0.0.1:$port');
  @override
  Uri get mapUrl => Uri.parse('http://127.0.0.1:$port/map.json');
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
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        await _reject(request, HttpStatus.notFound);
        return;
      }
      final channel = request.uri.queryParameters['channel'];
      if (channel == null || channel.isEmpty) {
        await _reject(request, HttpStatus.badRequest);
        return;
      }
      final protocols = _subprotocols(request);
      final bearerAt = protocols.indexOf('bearer');
      if (bearerAt < 0 || bearerAt + 1 >= protocols.length) {
        await _reject(request, HttpStatus.unauthorized);
        return;
      }
      final token = protocols[bearerAt + 1];
      final accepted = _options.acceptedTokens;
      if (token.isEmpty || (accepted != null && !accepted.contains(token))) {
        await _reject(request, HttpStatus.unauthorized);
        return;
      }
      final userId = _userIdOf(token);
      final gameId =
          request.uri.queryParameters['gameId'] ??
          request.headers.value('x-game-id');
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
    final game = _games.putIfAbsent(gameId, () => <String, _GameConnection>{});
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
        final handler = _options.onGameFrame;
        if (handler != null) {
          handler(connection, value);
        } else {
          connection.send(<String, Object?>{'type': 'echo', 'of': value});
        }
      },
      onDone: () {
        if (identical(game[userId], connection)) {
          game.remove(userId);
          if (game.isEmpty) _games.remove(gameId);
        }
      },
      onError: (Object _) {},
    );
    connection.send(<String, Object?>{
      'type': 'welcome',
      'gameId': gameId,
      'userId': userId,
      'members': game.keys.toList(),
    });
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
          _markOffline(userId);
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
    if (partyId != null) {
      _markOnline(userId);
      _broadcastRoster(_parties[partyId]!);
    }
    // A retained position resumes the zone.
    if (peer.zone != null) {
      _enterZone(connection, peer, peer.zone!, announce: true);
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
    if (zone == null || zone.isEmpty || x == null || y == null) {
      _send(c, _error('bad_zone', 'zone, x and y are required'));
      return;
    }
    final dirRaw = frame['dir'];
    if (dirRaw != null && dirRaw is! String) {
      _send(c, _error('bad_message', 'dir must be a string'));
      return;
    }
    final peer = _peers[c.userId]!;
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
    peer.moved = false;
    final inView = _peersInZone(zone).map((p) => p.toJson()).toList();
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

  Iterable<_Peer> _peersInZone(String zone) =>
      _lobby.keys.map((u) => _peers[u]!).where((p) => p.zone == zone);

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
    final allowed = _options.capabilities['say'];
    if (scope == null ||
        !const <String>['zone', 'party', 'user'].contains(scope) ||
        (allowed is List<Object?> && !allowed.contains(scope))) {
      _send(
        c,
        _error(
          scope == null ||
                  !const <String>['zone', 'party', 'user'].contains(scope)
              ? 'bad_scope'
              : 'capability_off',
          'scope',
        ),
      );
      return;
    }
    final text = frame.getString('text') ?? '';
    final name = frame.getString('name') ?? '';
    if (utf8.encode(text).length > 1024 || utf8.encode(name).length > 64) {
      _send(c, _error('too_long', 'text or name too long'));
      return;
    }
    final out = Json.object()
        .set('type', isEvent ? 'event' : 'say')
        .set('from', c.userId)
        .set('scope', scope)
        .set('to', frame.getString('to'))
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
    if (!_capability('party')) {
      _send(c, _error('capability_off', 'party is off'));
      return;
    }
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

  final Set<String> _offline = <String>{};
  void _markOffline(String userId) => _offline.add(userId);
  void _markOnline(String userId) => _offline.remove(userId);

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
      _safeAdd(c.socket, Json.encode(frame));

  void _sendTo(String userId, JsonObject frame) {
    final c = _lobby[userId];
    if (c != null) _send(c, frame);
  }

  void _broadcastZone(String zone, JsonObject frame, {String? except}) {
    final text = Json.encode(frame);
    for (final c in _lobby.values) {
      if (c.userId == except) continue;
      if (_peers[c.userId]?.zone != zone) continue;
      _safeAdd(c.socket, text);
    }
  }
}
