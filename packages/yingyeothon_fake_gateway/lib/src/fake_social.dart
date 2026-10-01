import 'dart:convert';
import 'dart:io';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// A card the fake social store starts with, so the offline demo has
/// players to befriend.
final class FakeSocialProfile {
  /// Creates a card.
  const FakeSocialProfile({
    required this.owner,
    required this.displayName,
    this.avatar,
  });

  /// The owner's id; here any plain segment, as the fake's identities are
  /// token texts.
  final String owner;

  /// 1 … 32 characters.
  final String displayName;

  /// An id or a path, or `null`.
  final String? avatar;
}

final class _Card {
  _Card(this.owner, this.displayName, this.avatar, this.updatedAt);
  final String owner;
  String displayName;
  String? avatar;
  int updatedAt;
}

/// One directed row: `from` → `to` in one of the four states.
final class _Row {
  _Row(this.from, this.to, this.state, this.at, {this.cooldownUntil});
  final String from;
  final String to;
  String state;
  int at;

  /// Set on a `dropped` row, and kept on a block that replaced one.
  int? cooldownUntil;
}

final class _Caller {
  _Caller(this.userId, this.isServer);
  final String userId;
  final bool isServer;
}

final class _Refusal implements Exception {
  _Refusal(this.status, this.code, this.message, [this.details]);
  final int status;
  final String code;
  final String message;
  final JsonObject? details;

  factory _Refusal.reason(String reason) => switch (reason) {
    'not_found' => _Refusal(
      404,
      'not_found',
      'player not found',
      <String, Object?>{'reason': reason},
    ),
    _ => _Refusal(
      409,
      'conflict',
      reason.replaceAll('_', ' '),
      <String, Object?>{'reason': reason},
    ),
  };
}

final class _Result {
  const _Result(this.status, this.body);
  _Result.json(this.status, Object? value) : body = Json.encode(value);
  final int status;
  final String? body;
}

/// The in-memory cards and relations behind `/social/*` on the fake
/// gateway. It follows `services/state/src/social.ts` and the planners in
/// `packages/console-db/src/social.ts` for the cases a client library
/// needs: a card admits a player to the graph, the four-state rows, mutual
/// requests settling at once, a decline kept as a cooldown the sender sees
/// as pending, a block that drops the peer's row but never their block, an
/// unblock that restores a cooldown, the caps, the shared `404`, and the
/// server key's reads, card writes and relation deletes. Identities are
/// token texts, so a player id is any plain segment and the server's 32-hex
/// rule on a token's subject is not enforced.
final class FakeSocialStore {
  /// Creates a store seeded with [profiles].
  FakeSocialStore(
    Iterable<FakeSocialProfile> profiles, {
    required String Function(String token) userIdOf,
    Set<String>? acceptedTokens,
    DateTime Function()? clock,
  }) : this._(profiles, userIdOf, acceptedTokens, clock ?? DateTime.now);

  FakeSocialStore._(
    Iterable<FakeSocialProfile> profiles,
    this._userIdOf,
    this._acceptedTokens,
    this._clock,
  ) {
    final at = _nowSec();
    for (final p in profiles) {
      _cards[p.owner] = _Card(p.owner, p.displayName, p.avatar, at);
    }
  }

  /// `SOCIAL_FRIENDS_MAX`.
  static const int friendsMax = 200;

  /// `SOCIAL_PENDING_OUT_MAX` and `SOCIAL_PENDING_IN_MAX`.
  static const int pendingMax = 100;

  /// `SOCIAL_BLOCKS_MAX`.
  static const int blocksMax = 500;

  /// `SOCIAL_PROFILES_PER_CHANNEL`.
  static const int profilesMax = 10000;

  /// `SOCIAL_PROFILE_IDS_MAX`.
  static const int profileIdsMax = 50;

  /// `SOCIAL_REQUEST_TTL_SEC`: a decline's cooldown.
  static const int requestTtlSec = 30 * 24 * 3600;

  static final RegExp _ownerPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
  );
  static final RegExp _avatarPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,31}(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,31}){0,3}$',
  );
  static final RegExp _nameRefused = RegExp(
    r'[\p{Cc}\p{Cf}\u2028\u2029]|\p{Mn}{5,}',
    unicode: true,
  );

  final String Function(String token) _userIdOf;
  final Set<String>? _acceptedTokens;
  final DateTime Function() _clock;
  final Map<String, _Card> _cards = <String, _Card>{};

  /// `from to` → row.
  final Map<String, _Row> _rows = <String, _Row>{};

  int _nowSec() => _clock().toUtc().millisecondsSinceEpoch ~/ 1000;

  static String _slot(String from, String to) => '$from $to';
  _Row? _row(String from, String to) => _rows[_slot(from, to)];
  void _put(_Row row) => _rows[_slot(row.from, row.to)] = row;
  void _drop(String from, String to) => _rows.remove(_slot(from, to));
  Iterable<_Row> _from(String id, List<String> states) =>
      _rows.values.where((r) => r.from == id && states.contains(r.state));
  Iterable<_Row> _to(String id, List<String> states) =>
      _rows.values.where((r) => r.to == id && states.contains(r.state));

  /// The state of the row `from` → `to`, or `null`.
  String? relation(String from, String to) => _row(from, to)?.state;

  /// The display name stored for [owner], or `null`.
  String? displayNameOf(String owner) => _cards[owner]?.displayName;

  /// Whether [path] is one this store serves.
  static bool handles(String path) =>
      path == '/social' || path.startsWith('/social/');

  /// Answers one request.
  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('cache-control', 'no-store');
    try {
      final body = await utf8.decoder.bind(request).join();
      final result = _dispatch(request, body);
      response.statusCode = result.status;
      if (result.body != null) {
        response.headers.contentType = ContentType.json;
        response.write(result.body);
      }
    } on _Refusal catch (e) {
      response.statusCode = e.status;
      response.headers.contentType = ContentType.json;
      response.write(
        Json.encode(<String, Object?>{
          'error': <String, Object?>{
            'code': e.code,
            'message': e.message,
            'details': ?e.details,
          },
        }),
      );
    }
    await response.close();
  }

  _Result _dispatch(HttpRequest request, String body) {
    final caller = _authenticate(request);
    final seg = request.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    final method = request.method;
    if (seg.length < 2 || seg.first != 'social') {
      throw _Refusal(404, 'not_found', 'no such route');
    }
    final rest = seg.sublist(1);
    _Result method405() =>
        throw _Refusal(405, 'method_not_allowed', 'method not allowed');
    switch (rest) {
      case ['me', 'profile']:
        final me = _playerOf(caller);
        return switch (method) {
          'GET' => _getProfile(me),
          'PUT' => _putProfile(me, body),
          'DELETE' => _deleteProfile(me),
          _ => method405(),
        };
      case ['profiles']:
        if (method != 'GET') return method405();
        return _profiles(request.uri.queryParameters['ids']);
      case ['friends']:
        if (method != 'GET') return method405();
        return _list('friends', _from(_playerOf(caller), ['friends']));
      case ['requests']:
        final me = _playerOf(caller);
        return switch (method) {
          'GET' => _Result.json(200, <String, Object?>{
            'incoming': _views(_to(me, ['requested']), (r) => r.from),
            'outgoing': _views(
              _from(me, ['requested', 'dropped']),
              (r) => r.to,
            ),
          }),
          'POST' => _request(me, body),
          _ => method405(),
        };
      case ['blocks']:
        if (method != 'GET') return method405();
        return _list('blocks', _from(_playerOf(caller), ['blocked']));
      case ['requests', final other, 'accept']:
        if (method != 'POST') return method405();
        return _done(_accept(_playerOf(caller), _playerId(other)));
      case ['requests', final other, 'decline']:
        if (method != 'POST') return method405();
        return _done(_decline(_playerOf(caller), _playerId(other)));
      case ['requests', final other]:
        if (method != 'DELETE') return method405();
        return _done(_withdraw(_playerOf(caller), _playerId(other)));
      case ['friends', final other]:
        if (method != 'DELETE') return method405();
        return _done(_unfriend(_playerOf(caller), _playerId(other)));
      case ['blocks', final other]:
        final me = _playerOf(caller);
        return switch (method) {
          'PUT' => _done(_block(me, _playerId(other))),
          'DELETE' => _done(_unblock(me, _playerId(other))),
          _ => method405(),
        };
      case ['u', final owner, 'friends']:
        if (method != 'GET') return method405();
        _requireServer(caller);
        final id = _playerId(owner);
        return _Result.json(200, <String, Object?>{
          'owner': id,
          'friends': _views(_from(id, ['friends']), (r) => r.to),
        });
      case ['u', final owner, 'profile']:
        _requireServer(caller);
        final id = _playerId(owner);
        return switch (method) {
          'PUT' => _putProfile(id, body),
          'DELETE' => _deleteProfile(id),
          _ => method405(),
        };
      case ['u', final owner, 'relations']:
        if (method != 'DELETE') return method405();
        _requireServer(caller);
        return _Result.json(200, <String, Object?>{
          'deleted': _deleteRelations(_playerId(owner), null),
        });
      case ['u', final owner, 'relations', final other]:
        if (method != 'DELETE') return method405();
        _requireServer(caller);
        return _Result.json(200, <String, Object?>{
          'deleted': _deleteRelations(_playerId(owner), _playerId(other)),
        });
    }
    throw _Refusal(404, 'not_found', 'no such route');
  }

  // ---- principals ----------------------------------------------------------

  _Caller _authenticate(HttpRequest request) {
    final header = request.headers.value('authorization') ?? '';
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix) || header.length == prefix.length) {
      throw _Refusal(401, 'unauthorized', 'missing bearer token');
    }
    final token = header.substring(prefix.length);
    final accepted = _acceptedTokens;
    if (accepted != null && !accepted.contains(token)) {
      throw _Refusal(401, 'unauthorized', 'token refused');
    }
    if (token.startsWith('yds.')) return _Caller('', true);
    return _Caller(_userIdOf(token), false);
  }

  String _playerOf(_Caller caller) {
    if (caller.isServer) {
      throw _Refusal(
        403,
        'forbidden',
        'a player token is required; a server key names the owner in the path',
      );
    }
    return caller.userId;
  }

  void _requireServer(_Caller caller) {
    if (!caller.isServer) {
      throw _Refusal(403, 'forbidden', 'a channel apiKey is required');
    }
  }

  String _playerId(String raw) {
    if (!_ownerPattern.hasMatch(raw)) {
      throw _Refusal(400, 'bad_request', 'invalid ownerId');
    }
    return raw;
  }

  // ---- cards ---------------------------------------------------------------

  static Map<String, Object?> _cardView(_Card c) => <String, Object?>{
    'owner': c.owner,
    'displayName': c.displayName,
    'avatar': c.avatar,
    'updatedAt': c.updatedAt,
  };

  _Result _getProfile(String owner) {
    final card = _cards[owner];
    if (card == null) throw _Refusal(404, 'not_found', 'profile not found');
    return _Result.json(200, _cardView(card));
  }

  _Result _putProfile(String owner, String body) {
    final decoded = Json.tryDecode(body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    final patch = value is JsonObject ? value : const <String, Object?>{};
    final rawName = patch['displayName'];
    if (rawName is! String) {
      throw _Refusal(400, 'bad_request', 'displayName is required');
    }
    final name = rawName.trim();
    final length = name.runes.length;
    if (length < 1 || length > 32) {
      throw _Refusal(400, 'bad_request', 'displayName must be 1-32 characters');
    }
    if (_nameRefused.hasMatch(name)) {
      throw _Refusal(
        400,
        'bad_request',
        'displayName must not contain control or format characters',
      );
    }
    final rawAvatar = patch['avatar'];
    String? avatar;
    if (rawAvatar != null) {
      if (rawAvatar is! String ||
          rawAvatar.length > 64 ||
          !_avatarPattern.hasMatch(rawAvatar)) {
        throw _Refusal(
          400,
          'bad_request',
          'avatar must be a short id or path, not a URL',
        );
      }
      avatar = rawAvatar;
    }
    final at = _nowSec();
    final existing = _cards[owner];
    if (existing == null) {
      if (_cards.length >= profilesMax) throw _Refusal.reason('channel_full');
      final card = _Card(owner, name, avatar, at);
      _cards[owner] = card;
      return _Result.json(201, _cardView(card));
    }
    // An identical PUT leaves updatedAt alone.
    if (existing.displayName != name || existing.avatar != avatar) {
      existing
        ..displayName = name
        ..avatar = avatar
        ..updatedAt = at;
    }
    return _Result.json(200, _cardView(existing));
  }

  _Result _deleteProfile(String owner) {
    if (_cards.remove(owner) == null) {
      throw _Refusal(404, 'not_found', 'profile not found');
    }
    // The owner's relations in both directions, except others' blocks of it.
    _rows.removeWhere(
      (_, r) => r.from == owner || (r.to == owner && r.state != 'blocked'),
    );
    return const _Result(204, null);
  }

  _Result _profiles(String? raw) {
    final ids = (raw ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (ids.length > profileIdsMax) {
      throw _Refusal(
        400,
        'bad_request',
        'at most $profileIdsMax ids per request',
      );
    }
    for (final id in ids) {
      _playerId(id);
    }
    return _Result.json(200, <String, Object?>{
      'profiles': <Object?>[
        for (final id in ids)
          if (_cards[id] case final c?) _cardView(c),
      ],
    });
  }

  // ---- lists ---------------------------------------------------------------

  List<Object?> _views(Iterable<_Row> rows, String Function(_Row) other) =>
      <Object?>[
        for (final r in rows)
          <String, Object?>{
            'owner': other(r),
            'displayName': _cards[other(r)]?.displayName,
            'avatar': _cards[other(r)]?.avatar,
            'since': r.at,
          },
      ];

  _Result _list(String key, Iterable<_Row> rows) =>
      _Result.json(200, <String, Object?>{key: _views(rows, (r) => r.to)});

  static _Result _done(void _) => const _Result(204, null);

  // ---- transitions (console-db/src/social.ts planners) --------------------

  void _requireCard(String id, String reason) {
    if (!_cards.containsKey(id)) throw _Refusal.reason(reason);
  }

  _Result _request(String me, String body) {
    final decoded = Json.tryDecode(body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    final raw = value is JsonObject ? value['to'] : null;
    final other = _playerId(raw is String ? raw : '');
    if (other == me) {
      throw _Refusal(400, 'bad_request', 'cannot befriend yourself');
    }
    _requireCard(me, 'profile_required');
    // No card, blocked me, no such player: one answer.
    if (!_cards.containsKey(other) || _row(other, me)?.state == 'blocked') {
      throw _Refusal.reason('not_found');
    }
    if (_row(me, other)?.state == 'blocked') throw _Refusal.reason('blocked');
    final at = _nowSec();
    final mine = _row(me, other);
    final theirs = _row(other, me);
    // A half friendship self-heals.
    if (mine?.state == 'friends' || theirs?.state == 'friends') {
      _put(_Row(me, other, 'friends', mine?.at ?? at));
      _put(_Row(other, me, 'friends', theirs?.at ?? at));
      return _Result.json(200, <String, Object?>{'state': 'friends'});
    }
    // A request already sent, declined or not: nothing moves.
    if (mine != null) {
      return _Result.json(200, <String, Object?>{'state': 'requested'});
    }
    // Mutual: settle at once, both friend caps checked; nothing new was
    // requested, so the service answers 200.
    if (theirs?.state == 'requested') {
      _checkFriendCaps(me, other);
      _put(_Row(me, other, 'friends', at));
      _put(_Row(other, me, 'friends', at));
      return _Result.json(200, <String, Object?>{'state': 'friends'});
    }
    if (_from(me, ['friends']).length >= friendsMax) {
      throw _Refusal.reason('friends_full');
    }
    if (_from(me, ['requested', 'dropped']).length >= pendingMax) {
      throw _Refusal.reason('pending_full');
    }
    if (_to(other, ['requested']).length >= pendingMax) {
      throw _Refusal.reason('peer_pending_full');
    }
    _put(_Row(me, other, 'requested', at));
    return _Result.json(201, <String, Object?>{'state': 'requested'});
  }

  void _checkFriendCaps(String me, String other) {
    if (_from(me, ['friends']).length >= friendsMax) {
      throw _Refusal.reason('friends_full');
    }
    if (_from(other, ['friends']).length >= friendsMax) {
      throw _Refusal.reason('peer_friends_full');
    }
  }

  void _accept(String me, String other) {
    final theirs = _row(other, me);
    if (theirs?.state != 'requested') throw _Refusal.reason('not_found');
    _checkFriendCaps(me, other);
    final at = _nowSec();
    _put(_Row(me, other, 'friends', at));
    _put(_Row(other, me, 'friends', at));
  }

  void _decline(String me, String other) {
    final theirs = _row(other, me);
    if (theirs?.state != 'requested') throw _Refusal.reason('not_found');
    theirs!
      ..state = 'dropped'
      ..at = _nowSec()
      ..cooldownUntil = _nowSec() + requestTtlSec;
  }

  void _withdraw(String me, String other) {
    // A dropped row is refused: withdrawing it would clear the cooldown.
    if (_row(me, other)?.state != 'requested') {
      throw _Refusal.reason('not_found');
    }
    _drop(me, other);
  }

  void _unfriend(String me, String other) {
    // Either row being friends is a friendship; only friend rows go.
    final mine = _row(me, other);
    final theirs = _row(other, me);
    if (mine?.state != 'friends' && theirs?.state != 'friends') {
      throw _Refusal.reason('not_found');
    }
    if (mine?.state == 'friends') _drop(me, other);
    if (theirs?.state == 'friends') _drop(other, me);
  }

  void _block(String me, String other) {
    if (other == me) {
      throw _Refusal(400, 'bad_request', 'cannot block yourself');
    }
    _requireCard(me, 'profile_required');
    final mine = _row(me, other);
    if (mine?.state == 'blocked') return;
    if (_from(me, ['blocked']).length >= blocksMax) {
      throw _Refusal.reason('blocks_full');
    }
    // The peer's row goes when it was a friendship or a request, never when
    // it is their own block.
    final theirs = _row(other, me);
    if (theirs != null && theirs.state != 'blocked') {
      _drop(other, me);
    }
    _put(
      _Row(
        me,
        other,
        'blocked',
        _nowSec(),
        // A cooldown the block replaced is kept for the unblock.
        cooldownUntil: mine?.state == 'dropped' ? mine!.cooldownUntil : null,
      ),
    );
  }

  void _unblock(String me, String other) {
    final mine = _row(me, other);
    if (mine?.state != 'blocked') throw _Refusal.reason('not_found');
    final cooldown = mine!.cooldownUntil;
    if (cooldown != null && cooldown > _nowSec()) {
      mine
        ..state = 'dropped'
        ..at = _nowSec();
    } else {
      _drop(me, other);
    }
  }

  int _deleteRelations(String player, String? other) {
    final before = _rows.length;
    _rows.removeWhere(
      (_, r) => other == null
          ? r.from == player || r.to == player
          : (r.from == player && r.to == other) ||
                (r.from == other && r.to == player),
    );
    return before - _rows.length;
  }
}
