// Drives the fake's `/lb/*` routes with a raw HttpClient, so the fake is
// tested against the protocol (`services/state/src/leaderboard.ts`), not
// against the client library it exists to test.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

final class Answer {
  Answer(this.status, this.body);
  final int status;
  final String body;
  Map<String, Object?> get json => jsonDecode(body) as Map<String, Object?>;
}

Future<Answer> call(
  Uri base,
  String method,
  String path, {
  String? token = 'alice',
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    return Answer(response.statusCode, await utf8.decodeStream(response));
  } finally {
    client.close();
  }
}

void main() {
  late FakeGateway gw;
  final at = DateTime.utc(2026, 9, 30, 20, 0); // 2026-10-01 05:00 KST, a Thu

  setUp(() async {
    gw = await FakeGateway.start(
      options: FakeGatewayOptions(
        clock: () => at,
        leaderboards: const <FakeLeaderboard>[
          FakeLeaderboard(
            name: 'race',
            submit: 'owner',
            rule: 'best',
            order: 'desc',
            periods: <String>['weekly', 'alltime'],
            maxEntries: 3,
            scores: <String, int>{'bob': 50, 'carol': 50, 'dave': 20},
          ),
          FakeLeaderboard(
            name: 'laps',
            submit: 'server',
            rule: 'latest',
            order: 'asc',
          ),
          FakeLeaderboard(name: 'coins', rule: 'sum', periods: ['daily']),
        ],
      ),
    );
  });

  tearDown(() => gw.shutdown());

  test('period keys and ends are computed in KST', () {
    final sec = at.millisecondsSinceEpoch ~/ 1000;
    expect(FakeLeaderboardStore.periodKey('alltime', sec), '');
    expect(FakeLeaderboardStore.periodKey('daily', sec), '2026-10-01');
    expect(FakeLeaderboardStore.periodKey('weekly', sec), '2026-W40');
    expect(FakeLeaderboardStore.periodEndsAt('alltime', sec), isNull);
    // 2026-10-02 00:00 KST = 2026-10-01 15:00 UTC.
    expect(
      FakeLeaderboardStore.periodEndsAt('daily', sec),
      DateTime.utc(2026, 10, 1, 15).millisecondsSinceEpoch ~/ 1000,
    );
    // The Monday after: 2026-10-05 00:00 KST.
    expect(
      FakeLeaderboardStore.periodEndsAt('weekly', sec),
      DateTime.utc(2026, 10, 4, 15).millisecondsSinceEpoch ~/ 1000,
    );
    // The two ISO-week boundaries the service pins.
    int secOf(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    expect(
      FakeLeaderboardStore.periodKey(
        'weekly',
        secOf(DateTime.utc(2027, 1, 1, 3)),
      ),
      '2026-W53',
    );
    expect(
      FakeLeaderboardStore.periodKey(
        'weekly',
        secOf(DateTime.utc(2024, 12, 30, 3)),
      ),
      '2025-W01',
    );
  });

  test('the board resolves by id or name before the credential', () async {
    final info = await call(gw.kvUrl, 'GET', '/lb/RACE');
    expect(info.status, 200);
    expect(info.json['id'], 'lb_race${'0' * 22}');
    expect(info.json['submit'], 'owner');
    expect(info.json['maxEntries'], 3);
    final periods = info.json['periods'] as List<Object?>;
    expect(periods.map((p) => (p! as Map)['period']), ['alltime', 'weekly']);
    expect((periods.last! as Map)['periodKey'], '2026-W40');
    final byId = await call(gw.kvUrl, 'GET', '/lb/lb_race${'0' * 22}');
    expect(byId.status, 200);
    expect((await call(gw.kvUrl, 'GET', '/lb/nope')).status, 404);
    expect((await call(gw.kvUrl, 'GET', '/lb/nope', token: null)).status, 401);
    // The board before the credential rule: a player on a `submit: server`
    // board that does not exist is the same 404, not a 403.
    expect(
      (await call(
        gw.kvUrl,
        'PUT',
        '/lb/nope/scores/me',
        body: '{"score":1}',
      )).status,
      404,
    );
  });

  test('submit judges by rule and order, writes every bucket', () async {
    // best/desc: 30 for a new player enters both buckets.
    var r = await call(
      gw.kvUrl,
      'PUT',
      '/lb/race/scores/me',
      body: '{"score":30,"meta":"{\\"k\\":1}"}',
    );
    expect(r.status, 409, reason: 'the bucket holds 3 already');
    expect((r.json['error']! as Map)['details'], {'reason': 'board_full'});
    // The server frees a row in every bucket.
    expect(
      (await call(
        gw.kvUrl,
        'DELETE',
        '/lb/race/scores/dave',
        token: 'yds.auth_0123456789abcdef.k',
      )).status,
      204,
    );
    expect(
      (await call(
        gw.kvUrl,
        'DELETE',
        '/lb/race/scores/dave',
        token: 'yds.auth_0123456789abcdef.k',
      )).status,
      404,
    );
    r = await call(
      gw.kvUrl,
      'PUT',
      '/lb/race/scores/me',
      body: '{"score":30,"meta":"{\\"k\\":1}"}',
    );
    expect(r.status, 200);
    expect(r.json['submitted'], 30);
    final stored = r.json['periods'] as List<Object?>;
    expect(stored.map((p) => (p! as Map)['score']), [30, 30]);
    // A worse score keeps the old row and its meta.
    r = await call(gw.kvUrl, 'PUT', '/lb/race/scores/me', body: '{"score":10}');
    expect(((r.json['periods'] as List<Object?>).first! as Map)['score'], 30);
    final mine = await call(gw.kvUrl, 'GET', '/lb/race/scores/me');
    expect(mine.json['meta'], '{"k":1}');
    expect(mine.json['rank'], 3, reason: '50, 50 share rank 1; 30 is 3rd');
    expect(mine.json['total'], 3);
    // A better one replaces the row and clears meta when none is sent.
    r = await call(gw.kvUrl, 'PUT', '/lb/race/scores/me', body: '{"score":60}');
    expect(((r.json['periods'] as List<Object?>).first! as Map)['score'], 60);
    expect(
      (await call(gw.kvUrl, 'GET', '/lb/race/scores/me')).json['meta'],
      isNull,
    );
    expect(gw.lb.scoreOf('race', 'alice'), 60);
    expect(gw.lb.scoreOf('race', 'alice', period: 'weekly'), 60);

    // latest/asc, submit: server — a player is refused whatever it names.
    expect(
      (await call(
        gw.kvUrl,
        'PUT',
        '/lb/laps/scores/me',
        body: '{"score":1}',
      )).status,
      403,
    );
    expect(
      (await call(
        gw.kvUrl,
        'PUT',
        '/lb/laps/scores/me',
        body: '{"score":1}',
        token: 'yds.auth_0123456789abcdef.k',
      )).status,
      400,
      reason: 'me from a server key',
    );
    r = await call(
      gw.kvUrl,
      'PUT',
      '/lb/laps/scores/alice',
      body: '{"score":90}',
      token: 'yds.auth_0123456789abcdef.k',
    );
    expect(r.status, 200);
    r = await call(
      gw.kvUrl,
      'PUT',
      '/lb/laps/scores/alice',
      body: '{"score":95}',
      token: 'yds.auth_0123456789abcdef.k',
    );
    expect(
      ((r.json['periods'] as List<Object?>).first! as Map)['score'],
      95,
      reason: 'latest replaces even a worse time',
    );
    // A player may not write another player's row on an owner board.
    expect(
      (await call(
        gw.kvUrl,
        'PUT',
        '/lb/race/scores/bob',
        body: '{"score":1}',
      )).status,
      403,
    );

    // sum saturates at the safe-integer bound.
    r = await call(
      gw.kvUrl,
      'PUT',
      '/lb/coins/scores/me',
      body: '{"score":9007199254740000}',
    );
    r = await call(
      gw.kvUrl,
      'PUT',
      '/lb/coins/scores/me',
      body: '{"score":9000}',
    );
    expect(
      ((r.json['periods'] as List<Object?>).first! as Map)['score'],
      9007199254740991,
    );
    expect(
      ((r.json['periods'] as List<Object?>).first! as Map)['periodKey'],
      '2026-10-01',
    );
  });

  test('the body is checked the way the service checks it', () async {
    Future<int> put(String body) async =>
        (await call(gw.kvUrl, 'PUT', '/lb/race/scores/me', body: body)).status;
    await call(
      gw.kvUrl,
      'DELETE',
      '/lb/race/scores/dave',
      token: 'yds.auth_0123456789abcdef.k',
    );
    expect(await put('{"score":"1"}'), 400);
    expect(await put('{"score":1.5}'), 400);
    expect(await put('{"score":9007199254740992}'), 400);
    expect(await put('{"score":1,"meta":{"a":1}}'), 400);
    expect(await put('{"score":1,"meta":"a\\u0000b"}'), 400);
    expect(await put('{"score":1,"meta":"${'x' * 1025}"}'), 413);
    expect(await put('{"score":1,"meta":"${'x' * 1024}"}'), 200);
    expect(await put('not json'), 400);
  });

  test(
    'top pages a bucket with shared ranks; a score reads one owner',
    () async {
      var top = await call(gw.kvUrl, 'GET', '/lb/race/top');
      expect(top.status, 200);
      expect(top.json['period'], 'alltime', reason: 'the first configured');
      expect(top.json['total'], 3);
      var entries = (top.json['entries'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(entries.map((e) => e['owner']), [
        'carol',
        'bob',
        'dave',
      ], reason: 'ties by owner in the scan direction (desc)');
      expect(entries.map((e) => e['rank']), [1, 1, 3]);
      top = await call(
        gw.kvUrl,
        'GET',
        '/lb/race/top?period=weekly&limit=1&offset=1',
      );
      expect(top.json['periodKey'], '2026-W40');
      entries = (top.json['entries'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(entries.single['owner'], 'bob');
      expect(entries.single['rank'], 1);
      expect(
        (await call(gw.kvUrl, 'GET', '/lb/race/top?period=daily')).status,
        400,
        reason: 'the board keeps no daily bucket',
      );
      expect(
        (await call(gw.kvUrl, 'GET', '/lb/race/top?period=monthly')).status,
        400,
      );
      expect(
        (await call(gw.kvUrl, 'GET', '/lb/race/top?offset=1001')).status,
        400,
      );
      expect(
        (await call(gw.kvUrl, 'GET', '/lb/race/top?offset=-1')).status,
        400,
      );
      expect(
        (await call(gw.kvUrl, 'GET', '/lb/race/top?limit=abc')).status,
        200,
        reason: 'a bad limit is the default',
      );
      final score = await call(
        gw.kvUrl,
        'GET',
        '/lb/race/scores/dave?period=weekly',
      );
      expect(score.json['owner'], 'dave');
      expect(score.json['rank'], 3);
      expect(score.json['total'], 3);
      expect((await call(gw.kvUrl, 'GET', '/lb/race/scores/me')).status, 404);
      expect(
        (await call(
          gw.kvUrl,
          'GET',
          '/lb/race/scores/me',
          token: 'yds.auth_0123456789abcdef.k',
        )).status,
        400,
      );
    },
  );

  test('deletes are the server key\'s; clear takes one batch', () async {
    expect((await call(gw.kvUrl, 'DELETE', '/lb/race/scores/bob')).status, 403);
    expect(
      (await call(gw.kvUrl, 'DELETE', '/lb/race/periods/alltime')).status,
      403,
    );
    final cleared = await call(
      gw.kvUrl,
      'DELETE',
      '/lb/race/periods/weekly',
      token: 'yds.auth_0123456789abcdef.k',
    );
    expect(cleared.status, 200);
    expect(cleared.json['deleted'], 3);
    expect(cleared.json['truncated'], isFalse);
    expect(cleared.json['periodKey'], '2026-W40');
    expect(
      (await call(gw.kvUrl, 'GET', '/lb/race/top?period=weekly')).json['total'],
      0,
    );
    expect(
      (await call(gw.kvUrl, 'GET', '/lb/race/top')).json['total'],
      3,
      reason: 'only the named period',
    );
    expect(
      (await call(
        gw.kvUrl,
        'DELETE',
        '/lb/race/periods/daily',
        token: 'yds.auth_0123456789abcdef.k',
      )).status,
      400,
    );
    expect((await call(gw.kvUrl, 'POST', '/lb/race/top')).status, 405);
    expect((await call(gw.kvUrl, 'GET', '/lb/race/nope')).status, 404);
  });
}
