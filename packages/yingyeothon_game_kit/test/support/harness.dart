import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_game_kit/yingyeothon_game_kit.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

import 'fake_web_socket.dart';

String jwt(String id, {int expiry = 2000}) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': id, 'exp': expiry}))).replaceAll('=', '')}.fixture';
String identity(String token) =>
    ((jsonDecode(
          utf8.decode(
            base64Url.decode(base64Url.normalize(token.split('.')[1])),
          ),
        ) as Map)['sub'])
        as String;
Future<void> drain([int rounds = 30]) async {
  for (var n = 0; n < rounds; n++) {
    await Future<void>.value();
  }
}

final class Row {
  Row(this.value, this.version, this.at, {this.from, this.expiry});
  Object? value;
  int version, at;
  String? from;
  int? expiry;
}

/// A deterministic HTTP state fixture, shapes copied from service route builders.
final class MemoryHttp extends http.BaseClient {
  int now = 1000;
  bool offline = false;
  final List<http.Request> requests = [];
  final Map<String, Row> rows = {};
  final Map<String, Map<String, Object?>> profiles = {};
  final Map<String, Set<String>> incoming = {}, friends = {}, blocks = {};
  final Map<String, Map<String, int>> scores = {};
  final Map<String, FakeMatchStore> matches = {};
  final FakePushStore push = FakePushStore();
  final List<(int, Object?)> scripted = [];
  Set<String> online = {};
  bool closed = false;
  int? failNext;
  Future<void> Function(http.Request)? beforeSend;
  int? Function(http.Request)? failWhen;
  final Set<String> sumBoards = {};
  void seed(String col, String owner, String key, Object? value) {
    rows['$col/$owner/$key'] = Row(value, 1, now);
  }

  http.StreamedResponse answer(
    int status,
    Object? value, {
    Map<String, String> headers = const {},
  }) {
    final bytes = utf8.encode(
      (status == 204 || status == 201) && value == null
          ? ''
          : jsonEncode(value),
    );
    return http.StreamedResponse(
      Stream.value(bytes),
      status,
      headers: headers,
      contentLength: bytes.length,
    );
  }

  http.StreamedResponse refusal(
    int status, {
    String? reason,
    int? current,
    int? retryAfter,
  }) => answer(status, {
    'error': {
      'code': status == 401
          ? 'unauthorized'
          : status == 403
          ? 'forbidden'
          : status == 404
          ? 'not_found'
          : status == 429
          ? 'rate_limited'
          : 'conflict',
      'details': {
        'reason': ?reason,
        'current': ?current,
        'retryAfter': ?retryAfter,
      },
    },
  });
  @override
  Future<http.StreamedResponse> send(http.BaseRequest raw) async {
    final request = raw as http.Request;
    requests.add(request);
    await beforeSend?.call(request);
    final chosenFailure = failWhen?.call(request);
    if (chosenFailure != null) return refusal(chosenFailure);
    if (offline) throw http.ClientException('private-url');
    if (failNext != null) {
      final status = failNext!;
      failNext = null;
      return refusal(status);
    }
    if (scripted.isNotEmpty) {
      final reply = scripted.removeAt(0);
      return answer(reply.$1, reply.$2);
    }
    final path = request.url.pathSegments;
    if (path.firstOrNull == 'time') {
      return answer(200, {
        'epochMs': now * 1000,
        'now': DateTime.fromMillisecondsSinceEpoch(now * 1000)
            .toIso8601String(),
      });
    }
    final user = identity(request.headers['authorization']!.substring(7));
    if (path.firstOrNull == 'presence') {
      return answer(200, {
        'type': 'presence',
        'users': [
          for (final id in request.url.queryParameters['users']!.split(','))
            {'userId': id, 'online': online.contains(id)},
        ],
      });
    }
    if (path.firstOrNull == 'push') {
      final body = jsonDecode(request.body) as Map;
      if (request.method == 'DELETE') {
        push.unregister(user, body['token'] as String, channel: path[1]);
        return answer(204, null);
      }
      final reason = push.register(
        user,
        body['token'] as String,
        body['project'] as String?,
        now: now,
        channel: path[1],
      );
      return reason == null
          ? answer(204, null)
          : answer(400, {
              'error': {'code': reason},
            });
    }
    if (path.firstOrNull == 'm') {
      final store = matches.putIfAbsent(
        path[1],
        () => FakeMatchStore(clock: () => now),
      );
      try {
        switch ((request.method, path.last)) {
          case ('POST', 'ticket'):
            return answer(200, store.submit(user));
          case ('GET', 'ticket'):
            final value = store.status(user);
            return value == null ? refusal(404) : answer(200, value);
          case ('DELETE', 'ticket'):
            store.cancel(user);
            return answer(204, null);
          case ('POST', 'accept'):
            return answer(200, store.accept(user));
          case ('POST', 'decline'):
            return answer(200, store.decline(user));
        }
      } on FakeMatchRefusal catch (e) {
        return refusal(e.status, reason: e.reason, retryAfter: e.retryAfter);
      }
    }
    if (path.firstOrNull == 'lb') return _board(request, user, path);
    if (path.firstOrNull == 'social') return _social(request, user, path);
    if (path.firstOrNull != 'kv') return refusal(404);
    final col = path[1];
    if (path.length == 2) {
      return answer(200, {
        'id': 'kv_${col.padRight(26, '0')}',
        'name': col,
        'readScope': col == 'content' ? 'project' : 'user',
        'writeScope': col == 'content'
            ? 'team'
            : col == 'mail'
            ? 'project'
            : 'user',
        'encrypted': false,
        'maxEntries': 10000,
        'maxEntriesPerOwner': 100,
      });
    }
    final owned = path[2] == 'u';
    final owner = owned ? (path[3] == 'me' ? user : path[3]) : '';
    final at = owned ? 4 : 2;
    final key = path.length > at + 1 ? path[at + 1] : null;
    rows.removeWhere((_, row) => row.expiry != null && row.expiry! <= now);
    final prefix = '$col/$owner/';
    if (key == null) {
      return answer(200, {
        'entries': [
          for (final entry in rows.entries.where(
            (e) => e.key.startsWith(prefix),
          ))
            if (entry.key
                .substring(prefix.length)
                .startsWith(request.url.queryParameters['prefix'] ?? ''))
              {
                'key': entry.key.substring(prefix.length),
                'version': entry.value.version,
                'bytes': jsonEncode(entry.value.value).length,
                'updatedAt': entry.value.at,
                'from': entry.value.from,
                'valueText': jsonEncode(entry.value.value),
                'expiresAt': entry.value.expiry,
              },
        ],
        'nextCursor': null,
      });
    }
    final slot = '$prefix$key';
    final row = rows[slot];
    Map<String, String> headers(Row r) => {
      'etag': '"${r.version}"',
      if (r.from != null) 'x-kv-from': r.from!,
      if (r.from != null) 'x-kv-at': '${r.at}',
      if (r.expiry != null) 'x-kv-expires-at': '${r.expiry}',
    };
    if (request.method == 'GET') {
      return row == null
          ? refusal(404)
          : answer(200, row.value, headers: headers(row));
    }
    final expected = request.headers['if-match'];
    if (expected != null && (row == null || expected != '"${row.version}"')) {
      if (request.method == 'DELETE' && row == null) return refusal(404);
      return refusal(409, current: row?.version);
    }
    if (request.headers['if-none-match'] == '*' && row != null) {
      return refusal(409, current: row.version);
    }
    if (request.method == 'DELETE') {
      if (row == null) return refusal(404);
      rows.remove(slot);
      return answer(204, null);
    }
    if (col == 'content') return refusal(403);
    if (col == 'mail' && owner != user && row != null) {
      return refusal(409, reason: 'exists');
    }
    var value = jsonDecode(request.body);
    if (request.method == 'PATCH') {
      final body = value as Map;
      final base = (row?.value ?? 0) as int;
      final next = base + (body['incr'] as int);
      if ((body['min'] != null && next < (body['min'] as int)) ||
          (body['max'] != null && next > (body['max'] as int))) {
        return answer(409, {
          'error': {
            'code': 'conflict',
            'details': {'reason': 'out_of_range', 'value': base},
          },
        });
      }
      value = next;
    }
    final ttl = int.tryParse(request.url.queryParameters['ttl'] ?? '');
    final fresh = Row(
      value,
      (row?.version ?? 0) + 1,
      now,
      from: owned ? user : null,
      expiry: ttl == null
          ? row?.expiry
          : ttl == 0
          ? null
          : now + ttl,
    );
    rows[slot] = fresh;
    return request.method == 'PATCH'
        ? answer(200, {
            'value': value,
            'version': fresh.version,
          }, headers: headers(fresh))
        : answer(row == null ? 201 : 204, null, headers: headers(fresh));
  }

  http.StreamedResponse _board(
    http.Request request,
    String user,
    List<String> path,
  ) {
    final board = path[1],
        period = request.url.queryParameters['period'] ?? 'alltime';
    final bucket = {
      'period': period,
      'periodKey': period == 'alltime' ? '' : '2026-W40',
      'periodEndsAt': period == 'alltime' ? null : now + 3600,
    };
    final values = scores.putIfAbsent(board, () => {});
    final ranked = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (path.length == 2) {
      return answer(200, {
        'id': 'lb_${board.padRight(26, '0')}',
        'name': board,
        'submit': board == 'server' ? 'server' : 'owner',
        'rule': sumBoards.contains(board) ? 'sum' : 'best',
        'order': 'desc',
        'maxEntries': 2000,
        'periods': [
          {'period': 'alltime', 'periodKey': '', 'periodEndsAt': null},
          {
            'period': 'weekly',
            'periodKey': '2026-W40',
            'periodEndsAt': now + 3600,
          },
        ],
      });
    }
    if (request.method == 'PUT') {
      if (board == 'server') return refusal(403);
      final body = jsonDecode(request.body) as Map;
      values[user] =
          (sumBoards.contains(board) ? (values[user] ?? 0) : 0) +
          (body['score'] as int);
      return answer(200, {
        'submitted': body['score'],
        'periods': [
          for (final p in ['alltime', 'weekly'])
            {
              'period': p,
              'periodKey': p == 'alltime' ? '' : '2026-W40',
              'periodEndsAt': p == 'alltime' ? null : now + 3600,
              'score': body['score'],
              'updatedAt': now,
            },
        ],
      });
    }
    if (path.last == 'top') {
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0'),
          limit = int.parse(request.url.queryParameters['limit'] ?? '20');
      return answer(200, {
        ...bucket,
        'total': ranked.length,
        'entries': [
          for (final entry in ranked.skip(offset).take(limit))
            {
              'owner': entry.key,
              'score': entry.value,
              'rank': ranked.indexOf(entry) + 1,
              'meta': null,
              'updatedAt': now,
            },
        ],
      });
    }
    if (!values.containsKey(user)) return refusal(404);
    return answer(200, {
      ...bucket,
      'owner': user,
      'score': values[user],
      'rank': ranked.indexWhere((e) => e.key == user) + 1,
      'total': ranked.length,
      'meta': null,
      'updatedAt': now,
    });
  }

  http.StreamedResponse _social(
    http.Request request,
    String user,
    List<String> path,
  ) {
    Map<String, Object?> profile(String id) =>
        profiles[id] ??
        {
          'owner': id,
          'displayName': id.substring(0, 4),
          'avatar': null,
          'updatedAt': now,
        };
    Map<String, Object?> relation(String id) => {
      'owner': id,
      'displayName': profile(id)['displayName'],
      'avatar': null,
      'since': now,
    };
    if (path.length > 2 && path[1] == 'me' && path[2] == 'profile') {
      if (request.method == 'GET') {
        return profiles[user] == null
            ? refusal(404)
            : answer(200, profiles[user]);
      }
      final body = jsonDecode(request.body) as Map<String, Object?>;
      profiles[user] = {'owner': user, ...body, 'updatedAt': now};
      return answer(201, profiles[user]);
    }
    if (path[1] == 'profiles') {
      return answer(200, {
        'profiles': [
          for (final id
              in request.url.queryParameters['ids']?.split(',') ?? <String>[])
            profile(id),
        ],
      });
    }
    if (path[1] == 'friends') {
      if (request.method == 'GET') {
        return answer(200, {
          'friends': [
            for (final id in friends[user] ?? <String>{}) relation(id),
          ],
        });
      }
      final other = path[2];
      friends[user]?.remove(other);
      friends[other]?.remove(user);
      return answer(204, null);
    }
    if (path[1] == 'blocks') {
      final other = path[2];
      if (request.method == 'DELETE') {
        blocks[user]?.remove(other);
      } else {
        (blocks[user] ??= {}).add(other);
        friends[user]?.remove(other);
        friends[other]?.remove(user);
        incoming[user]?.remove(other);
        incoming[other]?.remove(user);
      }
      return answer(204, null);
    }
    if (request.method == 'GET') {
      return answer(200, {
        'incoming': [
          for (final id in incoming[user] ?? <String>{}) relation(id),
        ],
        'outgoing': [
          for (final entry in incoming.entries)
            if (entry.value.contains(user)) relation(entry.key),
        ],
      });
    }
    if (path.length == 2) {
      final other = (jsonDecode(request.body) as Map)['to'] as String;
      if (blocks[other]?.contains(user) == true) return refusal(404);
      (incoming[other] ??= {}).add(user);
      return answer(201, {'created': true, 'state': 'pending'});
    }
    final other = path[2];
    incoming[user]?.remove(other);
    if (path.last == 'accept') {
      (friends[user] ??= {}).add(other);
      (friends[other] ??= {}).add(user);
    }
    return answer(204, null);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// Pure synchronous gateway double: reentrant events still pass through the SDK.
final class MemoryHub implements GatewayWebSocketFactory {
  final Map<String, FakeWebSocket> sockets = {};
  final Map<String, List<String>> parties = {};
  final Map<String, List<String>> invites = {};
  final List<({String user, JsonObject frame})> sent = [];
  int _serial = 0;
  bool dropTurns = false;
  final Set<String> dropNames = {};
  final Map<String, FakeWebSocket> matchSockets = {};
  final Map<String, JsonObject> pendingMatches = {};
  final Set<String> delayedMatches = {};
  List<String>? forcedMembers;
  int matchSize = 4;
  Object? matchResult;
  int _matches = 0;
  int _injectedSeq = 0;
  void deliverMatch(String user) {
    final frame = pendingMatches.remove(user);
    if (frame != null) matchSockets[user]?.serverSend(frame);
  }

  void control(String from, String to, String name, JsonObject data) {
    sockets[to]!.serverSend({
      'type': 'event',
      'from': from,
      'scope': 'user',
      'to': to,
      'name': name,
      'payload': {
        'v': 1,
        'roomId': partyOf(to),
        'senderSession': 'injected',
        'seq': ++_injectedSeq,
        'data': data,
      },
    });
  }

  JsonObject? tamper;
  String? partyOf(String user) =>
      parties.entries.where((e) => e.value.contains(user)).firstOrNull?.key;
  void roster(String user) {
    final party = partyOf(user);
    sockets[user]?.serverSend({
      'type': 'party',
      'partyId': party ?? '',
      if (party != null) 'leaderId': parties[party]!.first,
      'members': [
        for (final member in parties[party] ?? <String>[])
          {'userId': member, 'online': sockets.containsKey(member)},
      ],
      'invited': invites[party] ?? <String>[],
      'max': 4,
    });
  }

  void allRoster() {
    for (final user in sockets.keys.toList()) {
      roster(user);
    }
  }

  @override
  GatewayWebSocket connect(GatewayWebSocketRequest request) {
    final user = identity(request.subprotocols[1]);
    final socket = FakeWebSocket(request);
    if (request.url.host == 'match') {
      matchSockets[user] = socket;
      socket.onClose = () {
        if (matchSockets[user] == socket) matchSockets.remove(user);
      };
      scheduleMicrotask(() {
        if (socket.isClosed) return;
        socket.serverOpen();
        if (matchSockets.length >= matchSize) {
          final users = matchSockets.keys.toList();
          final members = forcedMembers ?? users;
          final frame = <String, Object?>{
            'type': 'matched',
            'matchId': 'match-${++_matches}',
            'partial': false,
            'result': matchResult,
            'members': [
              for (final u in members) {'userId': u},
            ],
          };
          for (final u in users) {
            if (delayedMatches.contains(u)) {
              pendingMatches[u] = frame;
            } else {
              matchSockets[u]?.serverSend(frame);
            }
          }
        }
      });
      return socket;
    }
    sockets[user] = socket;
    socket.onClose = () {
      if (sockets[user] == socket) {
        sockets.remove(user);
        allRoster();
      }
    };
    socket.onSend = (text) => _handle(user, jsonDecode(text) as JsonObject);
    scheduleMicrotask(() {
      if (socket.isClosed) return;
      socket.serverOpen();
      socket.serverSend({
        'type': 'hello',
        'userId': user,
        'connectionId': 'c',
        'tick': 200,
        'mapUrl': 'http://fake/map.json',
        'zone': 'zone',
        'capabilities': {
          'party': true,
          'event': true,
          'say': ['party', 'user'],
        },
        'aoi': {'maxPeers': 64},
      });
      roster(user);
    });
    return socket;
  }

  void _handle(String user, JsonObject frame) {
    sent.add((user: user, frame: frame));
    switch (frame['type']) {
      case 'party.create':
        if (partyOf(user) == null) {
          final id = 'room-${++_serial}';
          parties[id] = [user];
          invites[id] = [];
        }
        allRoster();
      case 'party.invite':
        final target = frame['userId'] as String;
        final party = partyOf(user)!;
        if (!sockets.containsKey(target)) {
          sockets[user]!.serverSend({
            'type': 'error',
            'code': 'unknown_user',
            'message': 'offline',
          });
          return;
        }
        invites[party]!.add(target);
        roster(user);
        sockets[target]!.serverSend({
          'type': 'party.invite',
          'partyId': party,
          'from': user,
        });
      case 'party.accept':
        final party = frame['partyId'] as String;
        if (!parties[party]!.contains(user)) parties[party]!.add(user);
        invites[party]!.remove(user);
        allRoster();
      case 'party.decline':
        final party = frame['partyId'] as String;
        invites[party]!.remove(user);
        allRoster();
      case 'party.leave':
        final party = partyOf(user);
        if (party != null) {
          parties[party]!.remove(user);
          if (parties[party]!.isEmpty) parties.remove(party);
        }
        allRoster();
      case 'event':
        final name = frame['name'] as String;
        if (dropNames.contains(name) || (dropTurns && name == 'kit.turn')) {
          return;
        }
        final to = frame['to'] as String?;
        final targets = to == null
            ? (parties[partyOf(user)] ?? <String>[])
            : [to];
        final payload = tamper != null && name == 'kit.turn'
            ? {...(frame['payload']! as JsonObject), 'data': tamper}
            : frame['payload'];
        for (final target in targets.toList()) {
          if (sockets[target]?.isClosed == true) continue;
          sockets[target]?.serverSend({
            'type': 'event',
            'from': user,
            'scope': frame['scope'],
            'name': name,
            'payload': payload,
            'to': ?to,
          });
        }
    }
  }
}

final class QueueStorage implements KitQueueStorage {
  final Map<String, List<KitQueuedWrite>> data = {};
  bool fail = false;
  @override
  Future<List<KitQueuedWrite>> load(String namespace) async {
    if (fail) throw StateError('private');
    return data[namespace] ?? [];
  }

  @override
  Future<void> store(String namespace, List<KitQueuedWrite> writes) async {
    if (fail) throw StateError('private');
    data[namespace] = List.of(writes);
  }
}

final class Messaging implements PushMessaging {
  final refresh = StreamController<String>.broadcast(sync: true),
      delivery = StreamController<PushMessage>.broadcast(sync: true);
  final topics = <String>[];
  @override
  Future<String?> getToken() async => 'device';
  @override
  Stream<String> get tokenRefreshed => refresh.stream;
  @override
  Stream<PushMessage> get messages => delivery.stream;
  @override
  Future<void> subscribe(String topic) async {
    topics.add('+$topic');
  }

  @override
  Future<void> unsubscribe(String topic) async {
    topics.add('-$topic');
  }

  Future<void> close() async {
    await refresh.close();
    await delivery.close();
  }
}

GameKitConfig config({bool deferred = false}) => GameKitConfig({
  'auth': {'channelId': 'auth'},
  'state': {'url': 'http://fake'},
  'gateway': {'url': 'ws://fake', 'lobbyChannelId': 'lobby'},
  'collections': {'save': 'save', 'content': 'content', 'mail': 'mail'},
  'boards': {'weekly': 'weekly', 'server': 'server'},
  'match': deferred
      ? {
          'mode': 'deferred',
          'apiBase': 'http://fake',
          'ticketUrl': 'http://fake/m/match/ticket',
          'channelId': 'match',
        }
      : {'url': 'ws://match', 'channelId': 'match'},
  'push': {
    'channelId': 'push_demo',
    'apiBase': 'http://fake',
    'topic': 'configured.topic',
  },
});
