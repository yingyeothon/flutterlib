import 'dart:convert';
import 'dart:io';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// A board the fake leaderboard store serves, as the console would have
/// created it. Seed [scores] (owner → score per period name) so the offline
/// demo has a ranking to show.
final class FakeLeaderboard {
  /// Creates a board.
  const FakeLeaderboard({
    required this.name,
    this.id,
    this.submit = 'owner',
    this.rule = 'best',
    this.order = 'desc',
    this.periods = const <String>['alltime'],
    this.maxEntries = 2000,
    this.scores = const <String, int>{},
  });

  /// The console name; matched case-insensitively on the path.
  final String name;

  /// The `lb_` id; `null` derives one from the name.
  final String? id;

  /// `server` or `owner`.
  final String submit;

  /// `best`, `latest` or `sum`.
  final String rule;

  /// `desc` or `asc`.
  final String order;

  /// A non-empty subset of `alltime`, `daily`, `weekly`; stored in that
  /// order whatever order is given.
  final List<String> periods;

  /// Rows one bucket may hold.
  final int maxEntries;

  /// Seed scores, owner → score, written into every live bucket at start.
  final Map<String, int> scores;

  /// [id], or one derived from [name] in the `lb_` shape.
  String get effectiveId {
    final given = id;
    if (given != null) return given;
    final base = name
        .toLowerCase()
        .replaceAll(RegExp('[^0-9a-z]'), '')
        .padRight(26, '0');
    return 'lb_${base.substring(0, 26)}';
  }
}

final class _Row {
  _Row(this.owner, this.score, this.meta, this.updatedAt);
  final String owner;
  int score;
  String? meta;
  int updatedAt;
}

final class _Board {
  _Board(this.spec)
    : periods = <String>[
        for (final p in FakeLeaderboardStore.periodNames)
          if (spec.periods.contains(p)) p,
      ];
  final FakeLeaderboard spec;
  final List<String> periods;

  /// `period key` → owner → row.
  final Map<String, Map<String, _Row>> buckets = <String, Map<String, _Row>>{};

  Map<String, _Row> bucket(String period, String key) =>
      buckets.putIfAbsent('$period $key', () => <String, _Row>{});
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
}

final class _Result {
  const _Result(this.status, this.body);
  _Result.json(this.status, Object? value) : body = Json.encode(value);
  final int status;
  final String? body;
}

/// The in-memory leaderboards behind `/lb/*` on the fake gateway. It
/// answers the way `services/state/src/leaderboard.ts` does for the cases a
/// client library needs: the board resolved by id or name before the
/// credential, the `submit` rule, one write to every bucket judged by
/// `rule` × `order`, `board_full` for the whole write, ranks as
/// `1 + count(better)` with ties sharing one, the period keys computed in
/// `Asia/Seoul`, and the server-only deletes. Identities are token texts
/// (`alice`), so an owner — `me` or a named one — is any plain segment and
/// the server's owner grammar is not enforced.
final class FakeLeaderboardStore {
  /// Creates a store serving [boards].
  FakeLeaderboardStore(
    Iterable<FakeLeaderboard> boards, {
    required String Function(String token) userIdOf,
    Set<String>? acceptedTokens,
    DateTime Function()? clock,
  }) : this._(boards, userIdOf, acceptedTokens, clock ?? DateTime.now);

  FakeLeaderboardStore._(
    Iterable<FakeLeaderboard> boards,
    this._userIdOf,
    this._acceptedTokens,
    this._clock,
  ) {
    for (final spec in boards) {
      final board = _Board(spec);
      final at = _nowSec();
      spec.scores.forEach((owner, score) {
        for (final period in board.periods) {
          board.bucket(period, periodKey(period, at))[owner] = _Row(
            owner,
            score,
            null,
            at,
          );
        }
      });
      _boards.add(board);
    }
  }

  /// The period names, in the server's canonical order.
  static const List<String> periodNames = <String>[
    'alltime',
    'daily',
    'weekly',
  ];

  static final RegExp _idPattern = RegExp(r'^lb_[0-9a-z]{26}$');
  static final RegExp _namePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
  );
  static final RegExp _ownerPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
  );
  static final RegExp _control = RegExp(r'[\u0000-\u001f\u007f-\u009f]');
  static const int _metaBytes = 1024;
  static const int _maxSafeInteger = 9007199254740991;
  static const int _limitDefault = 20;
  static const int _limitMax = 100;
  static const int _offsetMax = 1000;
  static const int _deleteBatch = 500;
  static const Duration _kst = Duration(hours: 9);

  final String Function(String token) _userIdOf;
  final Set<String>? _acceptedTokens;
  final DateTime Function() _clock;
  final List<_Board> _boards = <_Board>[];

  int _nowSec() => _clock().toUtc().millisecondsSinceEpoch ~/ 1000;

  /// The bucket key the server computes for [period] at [atSec], in KST:
  /// `''`, `YYYY-MM-DD` or ISO `YYYY-Www`.
  static String periodKey(String period, int atSec) {
    if (period == 'alltime') return '';
    final local = DateTime.fromMillisecondsSinceEpoch(
      atSec * 1000,
      isUtc: true,
    ).add(_kst);
    if (period == 'daily') {
      return '${local.year.toString().padLeft(4, '0')}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
    }
    // ISO week: the week of the Thursday in the same Monday-started week.
    final day = DateTime.utc(local.year, local.month, local.day);
    final thursday = day.add(Duration(days: 4 - day.weekday));
    final first = DateTime.utc(thursday.year);
    final week = (thursday.difference(first).inDays ~/ 7) + 1;
    return '${thursday.year.toString().padLeft(4, '0')}-W'
        '${week.toString().padLeft(2, '0')}';
  }

  /// The second the bucket of [period] at [atSec] ends; `null` for alltime,
  /// as the service answers.
  static int? periodEndsAt(String period, int atSec) {
    if (period == 'alltime') return null;
    final local = DateTime.fromMillisecondsSinceEpoch(
      atSec * 1000,
      isUtc: true,
    ).add(_kst);
    final day = DateTime.utc(local.year, local.month, local.day);
    final end = period == 'daily'
        ? day.add(const Duration(days: 1))
        : day.add(Duration(days: 8 - day.weekday));
    return end.subtract(_kst).millisecondsSinceEpoch ~/ 1000;
  }

  /// The stored score of [owner] in the live bucket of [period], or `null`.
  int? scoreOf(String board, String owner, {String period = 'alltime'}) {
    final b = _resolve(board);
    if (b == null) return null;
    return b.bucket(period, periodKey(period, _nowSec()))[owner]?.score;
  }

  /// Whether [path] is one this store serves.
  static bool handles(String path) => path == '/lb' || path.startsWith('/lb/');

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
    final segments = request.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    // /lb/{board}[/scores/{owner} | /top | /periods/{period}]
    if (segments.length < 2 || segments.first != 'lb') {
      throw _Refusal(404, 'not_found', 'no such route');
    }
    // The board before the credential, so an id is never an oracle.
    final board = _boardOf(segments[1]);
    final rest = segments.sublist(2);
    final method = request.method;
    final query = request.uri.queryParameters;
    if (rest.isEmpty) {
      if (method != 'GET') throw _Refusal(405, 'method_not_allowed', method);
      return _info(board);
    }
    if (rest.length == 1 && rest.first == 'top') {
      if (method != 'GET') throw _Refusal(405, 'method_not_allowed', method);
      return _top(board, query);
    }
    if (rest.length == 2 && rest.first == 'scores') {
      return switch (method) {
        'PUT' => _submit(board, caller, rest[1], body),
        'GET' => _score(board, caller, rest[1], query),
        'DELETE' => _deleteScore(board, caller, rest[1]),
        _ => throw _Refusal(405, 'method_not_allowed', method),
      };
    }
    if (rest.length == 2 && rest.first == 'periods') {
      if (method != 'DELETE') {
        throw _Refusal(405, 'method_not_allowed', method);
      }
      return _clear(board, caller, rest[1]);
    }
    throw _Refusal(404, 'not_found', 'no such route');
  }

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

  _Board? _resolve(String segment) {
    if (_idPattern.hasMatch(segment)) {
      for (final b in _boards) {
        if (b.spec.effectiveId == segment) return b;
      }
      return null;
    }
    if (!_namePattern.hasMatch(segment)) return null;
    final folded = segment.toLowerCase();
    if (_idPattern.hasMatch(folded)) return null;
    for (final b in _boards) {
      if (b.spec.name.toLowerCase() == folded) return b;
    }
    return null;
  }

  _Board _boardOf(String segment) =>
      _resolve(segment) ??
      (throw _Refusal(404, 'not_found', 'leaderboard not found'));

  String _ownerOf(_Caller caller, String raw) {
    if (raw == 'me') {
      if (caller.isServer) {
        throw _Refusal(
          400,
          'bad_request',
          "'me' names the owner of a player token; a server key must name the owner",
        );
      }
      return caller.userId;
    }
    if (!_ownerPattern.hasMatch(raw)) {
      throw _Refusal(400, 'bad_request', 'invalid ownerId');
    }
    return raw;
  }

  String _periodOf(_Board board, String? raw) {
    if (raw == null || raw.isEmpty) return board.periods.first;
    if (!periodNames.contains(raw)) {
      throw _Refusal(
        400,
        'bad_request',
        'period must be one of ${periodNames.join(', ')}',
      );
    }
    if (!board.periods.contains(raw)) {
      throw _Refusal(400, 'bad_request', 'this board keeps no $raw bucket');
    }
    return raw;
  }

  static Map<String, Object?> _bucketView(String period, int at) =>
      <String, Object?>{
        'period': period,
        'periodKey': periodKey(period, at),
        'periodEndsAt': periodEndsAt(period, at),
      };

  _Result _info(_Board board) {
    final at = _nowSec();
    return _Result.json(200, <String, Object?>{
      'id': board.spec.effectiveId,
      'name': board.spec.name,
      'submit': board.spec.submit,
      'rule': board.spec.rule,
      'order': board.spec.order,
      'maxEntries': board.spec.maxEntries,
      'periods': <Object?>[for (final p in board.periods) _bucketView(p, at)],
    });
  }

  bool _better(_Board board, int next, int stored) =>
      board.spec.order == 'asc' ? next < stored : next > stored;

  _Result _submit(_Board board, _Caller caller, String rawOwner, String body) {
    // Credential before parameters: the kind test needs no owner.
    if (!caller.isServer && board.spec.submit != 'owner') {
      throw _Refusal(403, 'forbidden', 'not allowed to submit to this board');
    }
    final owner = _ownerOf(caller, rawOwner);
    if (!caller.isServer && caller.userId != owner) {
      throw _Refusal(403, 'forbidden', 'not allowed to submit to this board');
    }
    final decoded = Json.tryDecode(body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    final patch = value is JsonObject ? value : const <String, Object?>{};
    final score = patch['score'];
    if (score is! int || score.abs() > _maxSafeInteger) {
      throw _Refusal(400, 'bad_request', 'score must be a safe integer');
    }
    final rawMeta = patch['meta'];
    String? meta;
    if (rawMeta != null) {
      if (rawMeta is! String) {
        throw _Refusal(
          400,
          'bad_request',
          'meta must be a string of JSON text, not an object',
        );
      }
      if (_control.hasMatch(rawMeta)) {
        throw _Refusal(
          400,
          'bad_request',
          'meta must not contain control characters',
        );
      }
      if (utf8.encode(rawMeta).length > _metaBytes) {
        throw _Refusal(
          413,
          'payload_too_large',
          'meta exceeds $_metaBytes bytes',
        );
      }
      meta = rawMeta;
    }
    final at = _nowSec();
    // A bucket at its cap refuses the whole submission.
    for (final period in board.periods) {
      final bucket = board.bucket(period, periodKey(period, at));
      if (!bucket.containsKey(owner) &&
          bucket.length >= board.spec.maxEntries) {
        throw _Refusal(409, 'conflict', 'bucket full', <String, Object?>{
          'reason': 'board_full',
        });
      }
    }
    final periods = <Object?>[];
    for (final period in board.periods) {
      final bucket = board.bucket(period, periodKey(period, at));
      final row = bucket[owner];
      if (row == null) {
        bucket[owner] = _Row(owner, score, meta, at);
      } else {
        final accepted = switch (board.spec.rule) {
          'latest' => true,
          'sum' => true,
          _ => _better(board, score, row.score),
        };
        if (accepted) {
          row.score = board.spec.rule == 'sum'
              ? (row.score + score).clamp(-_maxSafeInteger, _maxSafeInteger)
              : score;
          row.meta = meta;
          row.updatedAt = at;
        }
      }
      final stored = bucket[owner]!;
      periods.add(<String, Object?>{
        ..._bucketView(period, at),
        'score': stored.score,
        'updatedAt': stored.updatedAt,
      });
    }
    return _Result.json(200, <String, Object?>{
      'submitted': score,
      'periods': periods,
    });
  }

  List<_Row> _ranked(_Board board, Map<String, _Row> bucket) {
    final rows = bucket.values.toList();
    final asc = board.spec.order == 'asc';
    rows.sort((a, b) {
      final byScore = asc
          ? a.score.compareTo(b.score)
          : b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      // Ties order by owner in the scan's own direction.
      return asc ? a.owner.compareTo(b.owner) : b.owner.compareTo(a.owner);
    });
    return rows;
  }

  int _rankOf(_Board board, Map<String, _Row> bucket, int score) =>
      1 + bucket.values.where((r) => _better(board, r.score, score)).length;

  _Result _top(_Board board, Map<String, String> query) {
    final period = _periodOf(board, query['period']);
    final at = _nowSec();
    final bucket = board.bucket(period, periodKey(period, at));
    final rawLimit = int.tryParse(query['limit'] ?? '');
    final limit = (rawLimit ?? _limitDefault).clamp(1, _limitMax);
    final rawOffset = query['offset'];
    final offset = rawOffset == null || rawOffset.isEmpty
        ? 0
        : int.tryParse(rawOffset);
    if (offset == null || offset < 0) {
      throw _Refusal(
        400,
        'bad_request',
        'offset must be a non-negative integer',
      );
    }
    if (offset > _offsetMax) {
      throw _Refusal(400, 'bad_request', 'offset must be at most $_offsetMax');
    }
    final rows = _ranked(board, bucket);
    final page = rows.skip(offset).take(limit).toList();
    return _Result.json(200, <String, Object?>{
      ..._bucketView(period, at),
      'total': rows.length,
      'entries': <Object?>[
        for (final r in page)
          <String, Object?>{
            'rank': _rankOf(board, bucket, r.score),
            'owner': r.owner,
            'score': r.score,
            'meta': r.meta,
            'updatedAt': r.updatedAt,
          },
      ],
    });
  }

  _Result _score(
    _Board board,
    _Caller caller,
    String rawOwner,
    Map<String, String> query,
  ) {
    final owner = _ownerOf(caller, rawOwner);
    final period = _periodOf(board, query['period']);
    final at = _nowSec();
    final bucket = board.bucket(period, periodKey(period, at));
    final row = bucket[owner];
    if (row == null) throw _Refusal(404, 'not_found', 'score not found');
    return _Result.json(200, <String, Object?>{
      ..._bucketView(period, at),
      'owner': owner,
      'score': row.score,
      'meta': row.meta,
      'rank': _rankOf(board, bucket, row.score),
      'total': bucket.length,
      'updatedAt': row.updatedAt,
    });
  }

  void _requireServer(_Caller caller) {
    if (!caller.isServer) {
      throw _Refusal(
        403,
        'forbidden',
        'not allowed to delete scores on this board',
      );
    }
  }

  _Result _deleteScore(_Board board, _Caller caller, String rawOwner) {
    _requireServer(caller);
    final owner = _ownerOf(caller, rawOwner);
    var deleted = 0;
    for (final bucket in board.buckets.values) {
      if (bucket.remove(owner) != null) deleted++;
    }
    if (deleted == 0) throw _Refusal(404, 'not_found', 'score not found');
    return const _Result(204, null);
  }

  _Result _clear(_Board board, _Caller caller, String rawPeriod) {
    _requireServer(caller);
    final period = _periodOf(board, rawPeriod);
    final at = _nowSec();
    final bucket = board.bucket(period, periodKey(period, at));
    final owners = bucket.keys.take(_deleteBatch).toList();
    for (final o in owners) {
      bucket.remove(o);
    }
    return _Result.json(200, <String, Object?>{
      ..._bucketView(period, at),
      'deleted': owners.length,
      'truncated': owners.length >= _deleteBatch,
    });
  }
}
