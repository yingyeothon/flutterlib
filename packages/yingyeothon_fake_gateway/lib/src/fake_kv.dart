import 'dart:convert';
import 'dart:io';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// A collection the fake key-value store serves, as the console would have
/// created it. Seed [entries] (shared namespace) or [ownerEntries] (one map
/// per owner) so the offline demo has something to show.
final class FakeKvCollection {
  /// Creates a collection.
  const FakeKvCollection({
    required this.name,
    this.id,
    this.readScope = 'project',
    this.writeScope = 'project',
    this.encrypted = false,
    this.maxEntries = 10000,
    this.maxEntriesPerOwner = 100,
    this.entries = const <String, Object?>{},
    this.ownerEntries = const <String, Map<String, Object?>>{},
  });

  /// The console name; matched case-insensitively on the path.
  final String name;

  /// The `kv_` id; `null` derives one from the name.
  final String? id;

  /// `team`, `project` or `user`.
  final String readScope;

  /// `team`, `project` or `user`; `user` puts entries under `/u/{owner}`.
  final String writeScope;

  /// Reported in the meta; values are stored in the clear regardless.
  final bool encrypted;

  /// Entries the collection may hold.
  final int maxEntries;

  /// Entries one owner may hold.
  final int maxEntriesPerOwner;

  /// Seed values for the shared namespace.
  final Map<String, Object?> entries;

  /// Seed values per owner for a user namespace.
  final Map<String, Map<String, Object?>> ownerEntries;

  /// Whether entries live under `/u/{owner}`.
  bool get isUserNamespace => writeScope == 'user';

  /// [id], or one derived from [name] in the `kv_` shape.
  String get effectiveId {
    final given = id;
    if (given != null) return given;
    final base = name
        .toLowerCase()
        .replaceAll(RegExp('[^0-9a-z]'), '')
        .padRight(26, '0');
    return 'kv_${base.substring(0, 26)}';
  }
}

final class _Row {
  _Row(this.owner, this.key, this.text, this.version, this.expiresAt, this.at);
  final String owner;
  final String key;
  String text;
  int version;
  int? expiresAt;
  int at;

  bool live(int now) => expiresAt == null || expiresAt! > now;
}

final class _Collection {
  _Collection(this.spec);
  final FakeKvCollection spec;

  /// `(owner, key)` -> row; the shared namespace's owner is `''`.
  final Map<String, _Row> rows = <String, _Row>{};

  static String slot(String owner, String key) => '$owner $key';

  _Row? find(String owner, String key) => rows[slot(owner, key)];

  int liveCount(int now, {String? owner}) => rows.values
      .where((r) => r.live(now) && (owner == null || r.owner == owner))
      .length;
}

/// Who is calling: the doc apiKey (`yds.`) is the server, anything else a
/// player whose id is the token's user id.
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
}

/// The in-memory key-value store behind `/kv/*` on the fake gateway. It
/// answers the way `services/state` does for the cases a client library
/// needs: scopes, both namespaces, versions, conditional writes, TTL,
/// `incr`, listing with a cursor, and the documented refusals. Values are
/// never encrypted; `encrypted` is metadata only.
final class FakeKvStore {
  /// Creates a store serving [collections].
  FakeKvStore(
    Iterable<FakeKvCollection> collections, {
    required String Function(String token) userIdOf,
    Set<String>? acceptedTokens,
  }) : this._(collections, userIdOf, acceptedTokens);

  FakeKvStore._(
    Iterable<FakeKvCollection> collections,
    this._userIdOf,
    this._acceptedTokens,
  ) {
    for (final spec in collections) {
      final col = _Collection(spec);
      spec.entries.forEach((key, value) => _seed(col, '', key, value));
      spec.ownerEntries.forEach(
        (owner, entries) =>
            entries.forEach((key, value) => _seed(col, owner, key, value)),
      );
      _collections.add(col);
    }
  }

  static final RegExp _idPattern = RegExp(r'^kv_[0-9a-z]{26}$');
  static final RegExp _namePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
  );
  static final RegExp _keyPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
  );

  /// Wider than the server's `KV_OWNER_ID` (32 hex or `{kind}:{id}`) on
  /// purpose: the fake's identities are token texts (`alice`, `seed-1`), so
  /// an owner is any plain segment.
  static final RegExp _ownerPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
  );
  static const int _maxValueBytes = 16 * 1024;
  static const int _ttlMax = 366 * 24 * 60 * 60;
  static const int _maxSafeInteger = 9007199254740991;
  static const Object _keep = Object();

  final String Function(String token) _userIdOf;
  final Set<String>? _acceptedTokens;
  final List<_Collection> _collections = <_Collection>[];

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  void _seed(_Collection col, String owner, String key, Object? value) {
    col.rows[_Collection.slot(owner, key)] = _Row(
      owner,
      key,
      Json.encode(value),
      1,
      null,
      _now(),
    );
  }

  /// The stored JSON text of one entry, or `null`; an expired row is `null`
  /// too. The shared namespace's owner is `''`.
  String? valueText(String collection, String key, {String owner = ''}) {
    final col = _resolve(collection);
    if (col == null) return null;
    final row = col.find(owner, key);
    return row != null && row.live(_now()) ? row.text : null;
  }

  /// Whether [path] is one this store serves.
  static bool handles(String path) => path == '/kv' || path.startsWith('/kv/');

  /// Answers one request.
  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set('cache-control', 'no-store');
    try {
      final body = await utf8.decoder.bind(request).join();
      final result = _dispatch(request, body);
      response.statusCode = result.status;
      result.headers.forEach(response.headers.set);
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
    final segments = request.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    // /kv/{col}[/entries[/{key}] | /u/{owner}/entries[/{key}]]
    if (segments.length < 2 || segments.first != 'kv') {
      throw _Refusal(404, 'not_found', 'no such route');
    }
    final col = _collectionOf(segments[1]);
    final rest = segments.sublist(2);
    final method = request.method;
    if (rest.isEmpty) {
      if (method != 'GET') throw _Refusal(405, 'method_not_allowed', method);
      return _meta(col);
    }
    final String? owner;
    final List<String> tail;
    if (rest.first == 'u') {
      if (rest.length < 3 || rest[2] != 'entries') {
        throw _Refusal(404, 'not_found', 'no such route');
      }
      owner = _ownerOf(col, caller, rest[1]);
      tail = rest.sublist(3);
    } else if (rest.first == 'entries') {
      owner = null;
      if (col.spec.isUserNamespace && rest.length > 1) {
        throw _wrongNamespace('use /kv/{col}/u/me/entries');
      }
      tail = rest.sublist(1);
    } else {
      throw _Refusal(404, 'not_found', 'no such route');
    }
    if (tail.isEmpty) {
      if (method != 'GET') throw _Refusal(405, 'method_not_allowed', method);
      return _list(request, col, caller, owner);
    }
    if (tail.length != 1) throw _Refusal(404, 'not_found', 'no such route');
    final key = tail.single;
    if (!_keyPattern.hasMatch(key)) {
      throw _Refusal(400, 'bad_request', 'key must match the key grammar');
    }
    final slotOwner = owner ?? '';
    return switch (method) {
      'GET' => _get(col, caller, slotOwner, key),
      'PUT' => _put(request, body, col, caller, slotOwner, key),
      'PATCH' => _incr(request, body, col, caller, slotOwner, key),
      'DELETE' => _delete(request, col, caller, slotOwner, key),
      _ => throw _Refusal(405, 'method_not_allowed', method),
    };
  }

  // ---- principals and scopes ---------------------------------------------

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

  _Collection? _resolve(String segment) {
    if (_idPattern.hasMatch(segment)) {
      for (final col in _collections) {
        if (col.spec.effectiveId == segment) return col;
      }
      return null;
    }
    if (!_namePattern.hasMatch(segment)) return null;
    final folded = segment.toLowerCase();
    // A name that folds onto the id shape is refused without a lookup;
    // `kv_foo` is a legal name.
    if (_idPattern.hasMatch(folded)) return null;
    for (final col in _collections) {
      if (col.spec.name.toLowerCase() == folded) return col;
    }
    return null;
  }

  _Collection _collectionOf(String segment) {
    final col = _resolve(segment);
    if (col == null) throw _Refusal(404, 'not_found', 'collection not found');
    return col;
  }

  /// `me` is the player; a server key may name anyone.
  String _ownerOf(_Collection col, _Caller caller, String raw) {
    if (!col.spec.isUserNamespace) {
      throw _wrongNamespace('use /kv/{col}/entries');
    }
    if (raw == 'me') {
      if (caller.isServer) {
        throw _Refusal(400, 'bad_request', 'me needs a player token');
      }
      return caller.userId;
    }
    if (!_ownerPattern.hasMatch(raw)) {
      throw _Refusal(400, 'bad_request', 'owner must match the owner grammar');
    }
    return raw;
  }

  static _Refusal _wrongNamespace(String hint) => _Refusal(
    400,
    'bad_request',
    hint,
    <String, Object?>{'reason': 'wrong_namespace'},
  );

  /// The scope matrix: `team` refuses every API principal, `project` admits
  /// any, `user` admits the server and the owner of the target.
  static bool _allows(String scope, _Caller caller, String? targetOwner) {
    if (scope == 'team') return false;
    if (scope == 'project') return true;
    if (caller.isServer) return true;
    return targetOwner != null && targetOwner == caller.userId;
  }

  static bool _mayRead(_Collection col, _Caller caller, String? owner) =>
      _allows(col.spec.readScope, caller, owner);

  static void _requireRead(_Collection col, _Caller caller, String? owner) {
    if (!_mayRead(col, caller, owner)) {
      throw _Refusal(403, 'forbidden', 'readScope ${col.spec.readScope}');
    }
  }

  static void _requireWrite(_Collection col, _Caller caller, String? owner) {
    if (!_allows(col.spec.writeScope, caller, owner)) {
      throw _Refusal(403, 'forbidden', 'writeScope ${col.spec.writeScope}');
    }
  }

  // ---- routes -------------------------------------------------------------

  _Result _meta(_Collection col) {
    final spec = col.spec;
    if (spec.readScope == 'team' && spec.writeScope == 'team') {
      throw _Refusal(403, 'forbidden', 'team only');
    }
    return _Result.json(200, <String, Object?>{
      'id': spec.effectiveId,
      'name': spec.name,
      'readScope': spec.readScope,
      'writeScope': spec.writeScope,
      'encrypted': spec.encrypted,
      'maxEntries': spec.maxEntries,
      'maxEntriesPerOwner': spec.maxEntriesPerOwner,
    });
  }

  _Result _list(
    HttpRequest request,
    _Collection col,
    _Caller caller,
    String? owner,
  ) {
    // `/entries` on a user namespace lists every owner, a read right of its
    // own; on a shared one it is the shared slot.
    final target = owner ?? (col.spec.isUserNamespace ? null : '');
    _requireRead(col, caller, target);
    final q = request.uri.queryParameters;
    final prefix = q['prefix'] ?? '';
    if (prefix.isNotEmpty && !_keyPattern.hasMatch(prefix)) {
      throw _Refusal(400, 'bad_request', 'prefix must match the key grammar');
    }
    // The server clamps (`kvPageLimit`): a bad number is the default 50.
    final limit = (int.tryParse(q['limit'] ?? '') ?? 50).clamp(1, 100);
    final orderRaw = q['order'] ?? '';
    if (orderRaw != '' && orderRaw != 'asc' && orderRaw != 'desc') {
      throw _Refusal(400, 'bad_request', 'order must be asc or desc');
    }
    final desc = orderRaw == 'desc';
    final values = q['values'] == '1' || q['values'] == 'true';
    final cursorRaw = q['cursor'];
    var offset = 0;
    if (cursorRaw != null && cursorRaw.isNotEmpty) {
      final parsed = int.tryParse(cursorRaw);
      if (parsed == null || parsed < 0) {
        throw _Refusal(400, 'bad_request', 'bad cursor');
      }
      offset = parsed;
    }
    final now = _now();
    final rows =
        col.rows.values
            .where(
              (r) =>
                  r.live(now) &&
                  (target == null || r.owner == target) &&
                  r.key.startsWith(prefix),
            )
            .toList()
          ..sort((a, b) {
            final byOwner = a.owner.compareTo(b.owner);
            final c = byOwner != 0 ? byOwner : a.key.compareTo(b.key);
            return desc ? -c : c;
          });
    final page = rows.skip(offset).take(limit).toList();
    final more = offset + page.length < rows.length;
    return _Result.json(200, <String, Object?>{
      'entries': <Object?>[
        for (final r in page)
          <String, Object?>{
            if (col.spec.isUserNamespace) 'owner': r.owner,
            'key': r.key,
            'version': r.version,
            'bytes': utf8.encode(r.text).length,
            'expiresAt': r.expiresAt,
            'updatedAt': r.at,
            if (values) 'valueText': r.text,
          },
      ],
      if (more) 'nextCursor': '${offset + page.length}',
    });
  }

  _Result _get(_Collection col, _Caller caller, String owner, String key) {
    _requireRead(col, caller, owner);
    final row = col.find(owner, key);
    if (row == null || !row.live(_now())) {
      throw _Refusal(404, 'not_found', 'entry not found');
    }
    return _Result(200, row.text, <String, String>{
      'etag': '"${row.version}"',
      'x-kv-expires-at': ?row.expiresAt?.toString(),
    });
  }

  /// `?ttl=`: absent keeps, `0` clears, else seconds from now.
  Object? _ttlOf(HttpRequest request, int now) {
    final raw = request.uri.queryParameters['ttl'];
    if (raw == null || raw.isEmpty) return _keep;
    final n = int.tryParse(raw);
    if (n == null || n < 0 || n > _ttlMax) {
      throw _Refusal(400, 'bad_request', 'ttl must be 0 or 1..$_ttlMax');
    }
    return n == 0 ? null : now + n;
  }

  /// `If-Match` as a version, or `null`; `If-Match: 0` is refused.
  static int? _ifMatch(HttpRequest request) {
    final raw = request.headers.value('if-match');
    if (raw == null) return null;
    final m = RegExp(r'^(?:W/)?(?:"(\d{1,15})"|(\d{1,15}))$')
        .firstMatch(raw.trim());
    final version = m == null ? null : int.parse(m.group(1) ?? m.group(2)!);
    if (version == null || version == 0) {
      throw _Refusal(400, 'bad_request', 'If-Match must be a version');
    }
    return version;
  }

  static bool _ifNoneMatch(HttpRequest request) {
    final raw = request.headers.value('if-none-match');
    if (raw == null) return false;
    if (raw.trim() != '*') {
      throw _Refusal(400, 'bad_request', 'If-None-Match must be *');
    }
    return true;
  }

  static _Refusal _conflict(_Row? current, bool mayRead, {String? reason}) =>
      _Refusal(409, 'conflict', reason ?? 'version mismatch', <String, Object?>{
        'reason': ?reason,
        if (reason == null && mayRead) 'current': current?.version,
      });

  /// Caps are counted on create only; the per-owner cap bounds a player, not
  /// the server key.
  void _requireRoom(_Collection col, _Caller caller, String owner, int now) {
    if (col.liveCount(now) >= col.spec.maxEntries) {
      throw _conflict(null, false, reason: 'collection_full');
    }
    if (col.spec.isUserNamespace &&
        !caller.isServer &&
        col.liveCount(now, owner: owner) >= col.spec.maxEntriesPerOwner) {
      throw _conflict(null, false, reason: 'owner_full');
    }
  }

  /// Writes [text] into the slot, creating the row or bumping its version;
  /// an expired row keeps climbing, so a stale `If-Match` cannot land on the
  /// reborn key.
  _Row _write(
    _Collection col,
    _Row? existing,
    bool wasLive,
    String owner,
    String key,
    String text,
    Object? ttl,
    int now,
  ) {
    final _Row row;
    if (existing == null) {
      row = _Row(owner, key, text, 1, null, now);
      col.rows[_Collection.slot(owner, key)] = row;
    } else {
      row = existing
        ..text = text
        ..version = existing.version + 1
        ..at = now;
      if (!wasLive) row.expiresAt = null;
    }
    if (!identical(ttl, _keep)) row.expiresAt = ttl as int?;
    return row;
  }

  _Result _put(
    HttpRequest request,
    String body,
    _Collection col,
    _Caller caller,
    String owner,
    String key,
  ) {
    _requireWrite(col, caller, owner);
    final mayRead = _mayRead(col, caller, owner);
    final ifMatch = _ifMatch(request);
    final ifNoneMatch = _ifNoneMatch(request);
    if (ifMatch != null && ifNoneMatch) {
      throw _Refusal(400, 'bad_request', 'one conditional header at a time');
    }
    if ((ifMatch != null || ifNoneMatch) && !mayRead) {
      throw _Refusal(
        403,
        'forbidden',
        'a conditional write needs the read right',
      );
    }
    if (utf8.encode(body).length > _maxValueBytes) {
      throw _Refusal(413, 'payload_too_large', 'value exceeds 16 KiB');
    }
    if (Json.tryDecode(body) is! JsonDecoded) {
      throw _Refusal(400, 'bad_request', 'body must be JSON');
    }
    final now = _now();
    final ttl = _ttlOf(request, now);
    final existing = col.find(owner, key);
    final live = existing != null && existing.live(now) ? existing : null;
    if (ifNoneMatch && live != null) throw _conflict(live, mayRead);
    if (ifMatch != null && (live == null || live.version != ifMatch)) {
      throw _conflict(live, mayRead);
    }
    if (live == null) _requireRoom(col, caller, owner, now);
    final row = _write(col, existing, live != null, owner, key, body, ttl, now);
    final created = live == null;
    return _Result(mayRead && created ? 201 : 204, null, <String, String>{
      if (mayRead) 'etag': '"${row.version}"',
      if (!identical(ttl, _keep) && ttl != null) 'x-kv-expires-at': '$ttl',
    });
  }

  _Result _incr(
    HttpRequest request,
    String body,
    _Collection col,
    _Caller caller,
    String owner,
    String key,
  ) {
    _requireWrite(col, caller, owner);
    _requireRead(col, caller, owner);
    if (request.headers.value('if-match') != null ||
        request.headers.value('if-none-match') != null) {
      throw _Refusal(
        400,
        'bad_request',
        'If-Match and If-None-Match do not apply to PATCH',
      );
    }
    final now = _now();
    final ttl = _ttlOf(request, now);
    final decoded = Json.tryDecode(body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    final incr = value is JsonObject ? value.getInt('incr') : null;
    if (incr == null || incr.abs() > _maxSafeInteger) {
      throw _Refusal(400, 'bad_request', 'incr must be a safe integer');
    }
    final existing = col.find(owner, key);
    final live = existing != null && existing.live(now) ? existing : null;
    var base = 0;
    if (live != null) {
      final stored = Json.tryDecode(live.text);
      final current = stored is JsonDecoded ? stored.value : null;
      if (current is! int) {
        throw _conflict(null, true, reason: 'not_a_number');
      }
      base = current;
    }
    final next = base + incr;
    if (next.abs() > _maxSafeInteger) {
      throw _conflict(null, true, reason: 'overflow');
    }
    if (live == null) _requireRoom(col, caller, owner, now);
    final row = _write(
      col,
      existing,
      live != null,
      owner,
      key,
      '$next',
      ttl,
      now,
    );
    return _Result(
      200,
      Json.encode(<String, Object?>{'value': next, 'version': row.version}),
      <String, String>{
        'etag': '"${row.version}"',
        'x-kv-expires-at': ?row.expiresAt?.toString(),
      },
    );
  }

  _Result _delete(
    HttpRequest request,
    _Collection col,
    _Caller caller,
    String owner,
    String key,
  ) {
    _requireWrite(col, caller, owner);
    final mayRead = _mayRead(col, caller, owner);
    final ifMatch = _ifMatch(request);
    if (ifMatch != null && !mayRead) {
      throw _Refusal(
        403,
        'forbidden',
        'a conditional delete needs the read right',
      );
    }
    final now = _now();
    final existing = col.find(owner, key);
    final live = existing != null && existing.live(now) ? existing : null;
    // `deleteEntry` reports `missing` before it compares the version, and
    // "the key was not there" is a fact about stored data: a reader is told
    // 404, a write-only caller the idempotent 204.
    if (live == null) {
      if (mayRead) throw _Refusal(404, 'not_found', 'entry not found');
      return _Result(204, null, const <String, String>{});
    }
    if (ifMatch != null && live.version != ifMatch) {
      throw _conflict(live, mayRead);
    }
    // A real delete: the row goes, and a reborn key starts at version 1
    // (only an *expired* row keeps its version).
    col.rows.remove(_Collection.slot(owner, key));
    return _Result(204, null, const <String, String>{});
  }
}

final class _Result {
  const _Result(this.status, this.body, this.headers);
  _Result.json(this.status, Object? value)
    : body = Json.encode(value),
      headers = const <String, String>{};
  final int status;
  final String? body;
  final Map<String, String> headers;
}
