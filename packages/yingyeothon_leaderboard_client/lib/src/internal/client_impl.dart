import 'package:http/http.dart' as http;
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../errors.dart';
import '../leaderboard_client.dart';
import '../paths.dart';
import '../rules.dart';
import '../types.dart';
import 'requester.dart';

/// The client: one requester, many boards.
final class LeaderboardClientImpl implements LeaderboardClient {
  /// Creates the client; a `null` `client` option is one this owns.
  LeaderboardClientImpl(LeaderboardClientOptions options)
    : _requester = LbRequester(
        // Named arguments are evaluated in source order: the checks come
        // before the client is created, so a refused option leaks none.
        baseUrl: _checkBaseUrl(options.baseUrl),
        token: _checkToken(options.token),
        client: options.client ?? http.Client(),
        ownsClient: options.client == null,
        logger: options.logger ?? nullLogger,
        timeout: options.timeout ?? defaultTimeout,
      );

  /// The deadline when `LeaderboardClientOptions.timeout` is `null`.
  static const Duration defaultTimeout = Duration(seconds: 15);

  final LbRequester _requester;

  static Uri _checkBaseUrl(Uri url) {
    if ((url.scheme == 'https' || url.scheme == 'http') &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty &&
        !url.hasQuery &&
        !url.hasFragment) {
      return url;
    }
    // Never the URL: dart:io would quote it, and so would we.
    throw ArgumentError(
      'lb baseUrl must be an absolute http(s) URL with no user info, query or '
      'fragment',
    );
  }

  /// A bearer token is printable ASCII without spaces. `dart:io` refuses any
  /// other header value with a `FormatException` that quotes the whole
  /// header, so the check happens here, and names the index only.
  static String _checkToken(String token) {
    if (token.isEmpty) throw ArgumentError('lb token is required');
    for (var i = 0; i < token.length; i++) {
      final unit = token.codeUnitAt(i);
      if (unit <= 0x20 || unit >= 0x7f) {
        throw ArgumentError('lb token has an illegal character at index $i');
      }
    }
    return token;
  }

  @override
  Leaderboard board(String nameOrId) => LeaderboardImpl(_requester, nameOrId);

  @override
  void close() => _requester.close();
}

/// One board over the shared requester.
final class LeaderboardImpl implements Leaderboard {
  /// Creates a board over [ref]; checked here, so a bad ref throws at
  /// `board()` time rather than on the first call.
  LeaderboardImpl(this._requester, this.ref) : _board = LbPaths.board(ref);

  final LbRequester _requester;

  @override
  final String ref;

  final List<String> _board;

  static const LeaderboardException _malformed = LeaderboardException(
    200,
    LeaderboardException.malformedResponseCode,
  );

  /// Decodes a body the server promised would be a JSON object.
  static JsonObject _object(LbAnswer answer) {
    final decoded = Json.tryDecode(answer.body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    if (value is! JsonObject) throw _malformed;
    return value;
  }

  static LbEntry _entry(JsonObject row) => LbEntry(
    rank: row.getInt('rank') ?? 0,
    owner: row.getString('owner') ?? '',
    score: row.getInt('score') ?? 0,
    meta: row.getString('meta'),
    updatedAt: row.getInt('updatedAt') ?? 0,
    raw: row,
  );

  @override
  Future<LeaderboardInfo> info() async {
    final answer = await _requester.send('GET', LbRoute.board, _board);
    return LeaderboardInfo.fromJson(_object(answer));
  }

  @override
  Future<LbSubmitResult> submit(
    int score, {
    String owner = LbRules.selfOwner,
    String? meta,
  }) async {
    final path = LbPaths.score(ref, owner);
    final body = Json.object()
        .set('score', LbRules.checkScore(score))
        .set('meta', LbRules.checkMeta(meta))
        .build();
    final answer = await _requester.send(
      'PUT',
      LbRoute.score,
      path,
      body: Json.encode(body),
    );
    final json = _object(answer);
    return LbSubmitResult(
      submitted: json.getInt('submitted') ?? score,
      periods: <LbStoredScore>[
        for (final item in json.getListOrEmpty('periods'))
          if (item is JsonObject)
            LbStoredScore(
              bucket: LbBucket.fromJson(item),
              score: item.getInt('score') ?? 0,
              updatedAt: item.getInt('updatedAt') ?? 0,
            ),
      ],
    );
  }

  @override
  Future<LbPage> top({String? period, int? limit, int? offset}) async {
    final answer = await _requester.send(
      'GET',
      LbRoute.top,
      LbPaths.top(ref),
      query: LbPaths.topQuery(period: period, limit: limit, offset: offset),
    );
    final json = _object(answer);
    return LbPage(
      bucket: LbBucket.fromJson(json),
      total: json.getInt('total') ?? 0,
      entries: <LbEntry>[
        for (final item in json.getListOrEmpty('entries'))
          if (item is JsonObject) _entry(item),
      ],
    );
  }

  @override
  Future<LbScore?> score({
    String owner = LbRules.selfOwner,
    String? period,
  }) async {
    final path = LbPaths.score(ref, owner);
    final query = LbPaths.periodQuery(period);
    final LbAnswer answer;
    try {
      answer = await _requester.send('GET', LbRoute.score, path, query: query);
    } on LeaderboardException catch (e) {
      // No row for that owner is the one refusal that is an answer. A board
      // the caller cannot see is the same 404, which `info()` tells apart.
      if (e.status == 404) return null;
      rethrow;
    }
    final json = _object(answer);
    return LbScore(
      bucket: LbBucket.fromJson(json),
      owner: json.getString('owner') ?? '',
      score: json.getInt('score') ?? 0,
      rank: json.getInt('rank') ?? 0,
      total: json.getInt('total') ?? 0,
      updatedAt: json.getInt('updatedAt') ?? 0,
      meta: json.getString('meta'),
      raw: json,
    );
  }

  @override
  Future<bool> deleteScore(String owner) async {
    final path = LbPaths.score(ref, owner);
    try {
      await _requester.send('DELETE', LbRoute.score, path);
    } on LeaderboardException catch (e) {
      if (e.status == 404) return false;
      rethrow;
    }
    return true;
  }

  @override
  Future<LbClearResult> clearPeriod(String period) async {
    final answer = await _requester.send(
      'DELETE',
      LbRoute.period,
      LbPaths.period(ref, period),
    );
    final json = _object(answer);
    return LbClearResult(
      bucket: LbBucket.fromJson(json),
      deleted: json.getInt('deleted') ?? 0,
      truncated: json.getBool('truncated') ?? false,
    );
  }
}
