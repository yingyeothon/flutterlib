import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// A scripted match refusal, encoded by the fake HTTP listener.
final class FakeMatchRefusal implements Exception {
  /// Creates a refusal with safe service words.
  const FakeMatchRefusal(this.status, this.reason, {this.retryAfter});

  /// HTTP status.
  final int status;

  /// Service details.reason.
  final String reason;

  /// Cooldown seconds when applicable.
  final int? retryAfter;
}

/// In-memory deferred match state; no network or timer is needed to test it.
final class FakeMatchStore {
  /// Creates a FIFO store; call tick after advancing an injected clock.
  FakeMatchStore({
    this.partySize = 2,
    this.acceptTimeout = 30,
    this.waitTimeout = 60,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000) {
    if (partySize < 2 || acceptTimeout < 1 || waitTimeout < 1) {
      throw ArgumentError(
        'match limits must be positive, partySize at least two',
      );
    }
  }

  /// Number of waiting members forming a proposal.
  final int partySize;

  /// Proposal acceptance window and decliner cooldown in seconds.
  final int acceptTimeout;

  /// Waiting deadline in seconds.
  final int waitTimeout;
  final int Function() _clock;
  final Map<String, JsonObject> _tickets = {};
  final Map<String, int> _queuedAt = {};
  final Map<String, int> _enqueuedAt = {};
  final Map<String, int> _cooldown = {};
  final Map<String, List<String>> _proposals = {};
  int _serial = 0;
  int _orderSerial = 0;
  final Map<String, int> _order = {};
  final Map<String, ({int queued, int proposed})> _held = {};
  List<String> get _ordered =>
      _queuedAt.keys.toList()..sort((a, b) => _order[a]!.compareTo(_order[b]!));

  /// Submits, replacing an existing waiting ticket at the back of the queue.
  JsonObject submit(String user) {
    tick();
    final retry = (_cooldown[user] ?? 0) - _clock();
    if (retry > 0) throw FakeMatchRefusal(429, 'cooldown', retryAfter: retry);
    if (_tickets[user]?['state'] == 'proposed') {
      throw const FakeMatchRefusal(409, 'proposed');
    }
    _queuedAt.remove(user);
    _queuedAt[user] = _clock();
    _enqueuedAt[user] = _clock();
    _order[user] = ++_orderSerial;
    _tickets[user] = {
      'state': 'waiting',
      'position': _queuedAt.length,
      'waited': 0,
    };
    final submitted = Map<String, Object?>.of(_tickets[user]!);
    tick();
    return submitted;
  }

  /// Current ticket, copying the wire object.
  JsonObject? status(String user) {
    tick();
    final ticket = _tickets[user];
    return ticket == null ? null : Map.of(ticket);
  }

  /// Cancels waiting or declines proposed; missing is success.
  void cancel(String user) {
    tick();
    if (_tickets[user]?['state'] == 'proposed') {
      decline(user);
      _tickets.remove(user);
      return;
    }
    _tickets.remove(user);
    _queuedAt.remove(user);
  }

  /// Accepts idempotently; all acceptances confirm with identical members.
  JsonObject accept(String user) {
    tick();
    final ticket = _tickets[user];
    if (ticket == null) throw const FakeMatchRefusal(404, 'not_found');
    if (ticket['state'] == 'confirmed') return Map.of(ticket);
    if (ticket['state'] != 'proposed') {
      throw const FakeMatchRefusal(409, 'not_proposed');
    }
    ticket['accepted'] = true;
    final id = ticket['matchId']! as String;
    final members = _proposals[id]!;
    if (members.every((u) => _tickets[u]?['accepted'] == true)) {
      for (final u in members) {
        _tickets[u] = {
          'state': 'confirmed',
          'matchId': id,
          'partial': false,
          'result': null,
          'members': [
            for (final m in members) {'userId': m},
          ],
        };
      }
      _proposals.remove(id);
    }
    return Map.of(_tickets[user]!);
  }

  /// Declines and returns other members to waiting, applying a cooldown.
  JsonObject decline(String user) {
    tick();
    final ticket = _tickets[user];
    if (ticket == null) throw const FakeMatchRefusal(404, 'not_found');
    if (ticket['state'] == 'declined') return Map.of(ticket);
    if (ticket['state'] == 'confirmed') {
      throw const FakeMatchRefusal(409, 'confirmed');
    }
    if (ticket['state'] != 'proposed') {
      throw const FakeMatchRefusal(409, 'not_proposed');
    }
    final id = ticket['matchId']! as String;
    _endProposal(id, {user});
    _tickets[user] = {'state': 'declined', 'matchId': id};
    return Map.of(_tickets[user]!);
  }

  void _endProposal(String id, Set<String> expired) {
    for (final user in _proposals.remove(id) ?? <String>[]) {
      if (expired.contains(user)) {
        _tickets[user] = {
          'state': 'expired',
          'reason': 'accept',
          'matchId': id,
        };
        _cooldown[user] = _clock() + acceptTimeout;
      } else {
        final held = _held[user]!;
        _queuedAt[user] = held.queued + _clock() - held.proposed;
        _tickets[user] = {
          'state': 'waiting',
          'position': _queuedAt.length,
          'waited': 0,
        };
      }
      _held.remove(user);
    }
  }

  /// Applies deadlines and forms any full FIFO proposals.
  void tick() {
    final now = _clock();
    for (final entry in _proposals.entries.toList()) {
      final first = _tickets[entry.value.first]!;
      if (now >= (first['acceptBy']! as int)) {
        _endProposal(
          entry.key,
          entry.value.where((u) => _tickets[u]?['accepted'] != true).toSet(),
        );
      }
    }
    for (final entry in _queuedAt.entries.toList()) {
      if (now - entry.value >= waitTimeout) {
        _queuedAt.remove(entry.key);
        _tickets[entry.key] = {'state': 'expired', 'reason': 'wait'};
      }
    }
    while (_queuedAt.length >= partySize) {
      final members = _ordered.take(partySize).toList();
      final id = 'match-${++_serial}';
      _proposals[id] = members;
      for (final user in members) {
        _held[user] = (queued: _queuedAt[user]!, proposed: now);
        _queuedAt.remove(user);
        _tickets[user] = {
          'state': 'proposed',
          'matchId': id,
          'acceptBy': now + acceptTimeout,
          'accepted': false,
          'partial': false,
        };
      }
    }
    var position = 0;
    for (final user in _ordered) {
      final queued = _enqueuedAt[user]!;
      _tickets[user] = {
        'state': 'waiting',
        'position': ++position,
        'waited': now - queued,
      };
    }
  }

  /// Simulates a callback or inactive-channel failure.
  void fail(String user, {String reason = 'callback'}) {
    if (!['callback', 'closed'].contains(reason)) {
      throw ArgumentError('failure reason must be callback or closed');
    }
    _queuedAt.remove(user);
    for (final entry in _proposals.entries.toList()) {
      if (entry.value.contains(user)) {
        final members = _proposals.remove(entry.key)!;
        for (final member in members) {
          _tickets[member] = {
            'state': 'failed',
            'reason': reason,
            'matchId': entry.key,
          };
        }
        return;
      }
    }
    _tickets[user] = {'state': 'failed', 'reason': reason};
  }
}

/// Loopback HTTP tickets and live match sockets for SDK integration tests.
abstract interface class FakeMatchServer {
  /// Starts a listener. Plain tokens are identities; JWTs use sub without verification.
  static Future<FakeMatchServer> start({
    int partySize = 2,
    int acceptTimeout = 30,
    int waitTimeout = 60,
    int Function()? clock,
  }) => _FakeMatchServer.start(partySize, acceptTimeout, waitTimeout, clock);

  /// Base for deferred tickets.
  Uri get httpUrl;

  /// Origin for live matchmaking.
  Uri get wsUrl;

  /// State for a channel, useful for explicitly injected failures.
  FakeMatchStore store(String channel);

  /// Closes listener and sockets.
  Future<void> shutdown();
}

final class _FakeMatchServer implements FakeMatchServer {
  _FakeMatchServer(
    this._server,
    this._partySize,
    this._acceptTimeout,
    this._waitTimeout,
    this._clock,
  );
  static Future<FakeMatchServer> start(
    int size,
    int accept,
    int wait,
    int Function()? clock,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _FakeMatchServer(server, size, accept, wait, clock);
    server.listen(instance._handle);
    return instance;
  }

  final HttpServer _server;
  final int _partySize, _acceptTimeout, _waitTimeout;
  final int Function()? _clock;
  final Map<String, FakeMatchStore> _stores = {};
  final Map<String, Map<String, WebSocket>> _live = {};
  final Set<WebSocket> _sockets = {};
  int _serial = 0;
  @override
  Uri get httpUrl => Uri.parse('http://127.0.0.1:${_server.port}');
  @override
  Uri get wsUrl => httpUrl.replace(scheme: 'ws');
  @override
  FakeMatchStore store(String channel) => _stores.putIfAbsent(
    channel,
    () => FakeMatchStore(
      partySize: _partySize,
      acceptTimeout: _acceptTimeout,
      waitTimeout: _waitTimeout,
      clock: _clock,
    ),
  );
  String _identity(String token) {
    try {
      final parts = token.split('.');
      if (parts.length == 3) {
        final claims = Json.decode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        if (claims is JsonObject && claims.getString('sub') != null) {
          return claims.getString('sub')!;
        }
      }
    } on Exception {
      /* plain fake identities are supported */
    }
    return token;
  }

  Future<void> _answer(HttpRequest request, int status, [Object? value]) async {
    request.response.statusCode = status;
    request.response.headers.set('cache-control', 'no-store');
    if (value != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(Json.encode(value));
    }
    await request.response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final channel = request.uri.queryParameters['channel'];
        final protocols =
            request.headers
                .value('sec-websocket-protocol')
                ?.split(',')
                .map((s) => s.trim())
                .toList() ??
            [];
        if (channel == null) {
          await _answer(request, 400);
          return;
        }
        if (protocols.length < 2 || protocols.first != 'bearer') {
          await _answer(request, 401);
          return;
        }
        final user = _identity(protocols[1]);
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (_) => 'bearer',
        );
        _sockets.add(socket);
        final queue = _live.putIfAbsent(channel, () => {});
        queue.remove(user)?.add(Json.encode({'type': 'replaced'}));
        queue[user] = socket;
        socket.listen(
          (Object? message) {
            if (message is String) {
              final decoded = Json.tryDecode(message);
              if (decoded is JsonDecoded &&
                  decoded.value is JsonObject &&
                  (decoded.value as JsonObject)['type'] == 'ping') {
                socket.add(
                  Json.encode({
                    'type': 'pong',
                    'position': queue.keys.toList().indexOf(user) + 1,
                    'waited': 0,
                  }),
                );
              }
            }
          },
          onDone: () {
            if (queue[user] == socket) queue.remove(user);
            _sockets.remove(socket);
          },
        );
        if (queue.length >= _partySize) {
          final users = queue.keys.take(_partySize).toList();
          final frame = {
            'type': 'matched',
            'matchId': 'live-${++_serial}',
            'partial': false,
            'result': null,
            'members': [
              for (final u in users) {'userId': u},
            ],
          };
          for (final u in users) {
            queue.remove(u)!.add(Json.encode(frame));
          }
        }
        return;
      }
      final auth = request.headers.value('authorization');
      if (auth == null || !auth.startsWith('Bearer ') || auth.length <= 7) {
        await _answer(request, 401);
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length != 3 || segments.first != 'm') {
        await _answer(request, 404);
        return;
      }
      final state = store(segments[1]);
      final user = _identity(auth.substring(7));
      final route = segments.last;
      switch ((request.method, route)) {
        case ('POST', 'ticket'):
          await _answer(request, 200, state.submit(user));
        case ('GET', 'ticket'):
          final ticket = state.status(user);
          await _answer(request, ticket == null ? 404 : 200, ticket);
        case ('DELETE', 'ticket'):
          state.cancel(user);
          await _answer(request, 204);
        case ('POST', 'accept'):
          await _answer(request, 200, state.accept(user));
        case ('POST', 'decline'):
          await _answer(request, 200, state.decline(user));
        default:
          await _answer(request, 404);
      }
    } on FakeMatchRefusal catch (e) {
      await _answer(request, e.status, {
        'error': {
          'code': e.status == 429 ? 'rate_limited' : 'conflict',
          'details': {
            'reason': e.reason,
            if (e.retryAfter != null) 'retryAfter': e.retryAfter,
          },
        },
      });
    } on Exception {
      await _answer(request, 500);
    }
  }

  @override
  Future<void> shutdown() async {
    await Future.wait(_sockets.toList().map((s) => s.close()));
    await _server.close(force: true);
  }
}
