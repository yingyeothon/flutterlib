import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_leaderboard_client/yingyeothon_leaderboard_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'fake_http_client.dart';

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

/// Runs [body] and returns the [LeaderboardException] it threw, asserting
/// that its string is the code-and-status template and nothing else.
Future<LeaderboardException> refused(Future<Object?> Function() body) async {
  try {
    await body();
  } on LeaderboardException catch (e) {
    expect(e.toString(), 'LeaderboardException(${e.code}, ${e.status})');
    return e;
  }
  fail('expected a LeaderboardException');
}

// Reply fixtures below are copied from the route handlers in the service's
// `services/state/src/leaderboard.ts` (`bucketView`, `scoreView`, `submit`,
// the `/top` and `/scores/{ownerId}` handlers), never from the parser.
const String owner32 = '438497d4550fd6d399c259636e3375d7';
const String infoBody =
    '{"id":"lb_01j9x3k2m4n5p6q7r8s9t0u1v2","name":"weekly-race","submit":"owner",'
    '"rule":"best","order":"desc","maxEntries":2000,"periods":['
    '{"period":"alltime","periodKey":"","periodEndsAt":null},'
    '{"period":"weekly","periodKey":"2026-W40","periodEndsAt":1791759600}]}';
const String submitBody =
    '{"submitted":1200,"periods":['
    '{"period":"alltime","periodKey":"","periodEndsAt":null,"score":1500,"updatedAt":1759276800},'
    '{"period":"weekly","periodKey":"2026-W40","periodEndsAt":1791759600,"score":1200,"updatedAt":1759300000}]}';
const String topBody =
    '{"period":"weekly","periodKey":"2026-W40","periodEndsAt":1791759600,"total":3,"entries":['
    '{"rank":1,"owner":"$owner32","score":1500,"meta":"{\\"build\\":9007199254740993}","updatedAt":1759300000},'
    '{"rank":2,"owner":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","score":900,"meta":null,"updatedAt":1759290000}]}';
const String scoreBody =
    '{"period":"alltime","periodKey":"","periodEndsAt":null,"owner":"$owner32",'
    '"score":1500,"meta":null,"rank":1,"total":3,"updatedAt":1759300000}';
const String clearBody =
    '{"period":"weekly","periodKey":"2026-W40","periodEndsAt":1791759600,"deleted":500,"truncated":true}';

void main() {
  late FakeHttp fake;
  late CapturingLogWriter log;
  late LeaderboardClient client;

  setUp(() {
    fake = FakeHttp();
    log = CapturingLogWriter();
    client = LeaderboardClient(
      LeaderboardClientOptions(
        baseUrl: Uri.parse('https://doc.example'),
        token: fixtureToken,
        client: fake,
        logger: createFilteredLogger(severity: LogSeverity.debug, writer: log),
      ),
    );
  });

  group('options', () {
    test('refuse a relative or non-http base URL and a bad token', () {
      LeaderboardClientOptions options(Uri url, [String token = 't']) =>
          LeaderboardClientOptions(baseUrl: url, token: token, client: fake);
      expect(
        () => LeaderboardClient(options(Uri.parse('/lb'))),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'lb baseUrl must be an absolute http(s) URL with no user info, query or fragment',
          ),
        ),
      );
      for (final url in <String>[
        'wss://doc.example',
        'https://u:p@doc.example',
        'https://doc.example/?x=1',
        'https://doc.example/#f',
      ]) {
        expect(
          () => LeaderboardClient(options(Uri.parse(url))),
          throwsArgumentError,
          reason: url,
        );
      }
      expect(
        () => LeaderboardClient(options(Uri.parse('https://doc.example'), '')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'lb token is required',
          ),
        ),
      );
      // The index, never the character.
      expect(
        () => LeaderboardClient(
          options(Uri.parse('https://doc.example'), 'abéc'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'lb token has an illegal character at index 2',
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('board() checks the ref; the other grammars at call time', () {
      expect(client.board('weekly-race').ref, 'weekly-race');
      expect(client.board('lb_01j9x3k2m4n5p6q7r8s9t0u1v2').ref, isNotEmpty);
      for (final bad in <String>['', '-x', 'a b', 'a' * 65, 'lb/x', 'a:b']) {
        expect(() => client.board(bad), throwsArgumentError, reason: bad);
      }
      expect(
        () => client.board('a' * 64),
        returnsNormally,
        reason: 'the name grammar allows 64',
      );
      final board = client.board('b');
      expect(() => board.submit(1, owner: 'ME'), throwsArgumentError);
      expect(() => board.submit(1, owner: 'x' * 31), throwsArgumentError);
      expect(() => board.score(owner: 'guild:'), throwsArgumentError);
      expect(() => board.deleteScore('bad owner'), throwsArgumentError);
      expect(() => board.top(period: 'monthly'), throwsArgumentError);
      expect(() => board.top(limit: 0), throwsArgumentError);
      expect(() => board.top(limit: 101), throwsArgumentError);
      expect(() => board.top(offset: -1), throwsArgumentError);
      expect(() => board.top(offset: 1001), throwsArgumentError);
      expect(() => board.clearPeriod('2026-W40'), throwsArgumentError);
      expect(() => board.submit(LbRules.scoreMax + 1), throwsArgumentError);
      expect(() => board.submit(-LbRules.scoreMax - 1), throwsArgumentError);
      expect(() => board.submit(1, meta: 'a\u0000b'), throwsArgumentError);
      expect(() => board.submit(1, meta: 'a\u0085b'), throwsArgumentError);
      expect(
        () => board.submit(1, meta: 'é' * 513),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'lb meta exceeds 1024 bytes',
          ),
        ),
        reason: 'bytes, not characters',
      );
      expect(fake.requests, isEmpty);
    });
  });

  group('routes', () {
    test('info: GET /lb/{board}', () async {
      fake.answer(200, infoBody);
      final info = await client.board('weekly-race').info();
      final request = fake.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://doc.example/lb/weekly-race');
      expect(request.headers['authorization'], 'Bearer $fixtureToken');
      expect(request.headers['accept'], 'application/json');
      expect(info.id, 'lb_01j9x3k2m4n5p6q7r8s9t0u1v2');
      expect(info.name, 'weekly-race');
      expect(info.submit, LbSubmit.owner);
      expect(info.rule, LbRule.best);
      expect(info.order, LbOrder.desc);
      expect(info.maxEntries, 2000);
      expect(info.periods.map((b) => b.period), ['alltime', 'weekly']);
      expect(info.periods.last.periodKey, '2026-W40');
      expect(info.periods.last.periodEndsAt, 1791759600);
      expect(info.periods.first.periodKey, '');
      expect(info.periods.first.periodEndsAt, isNull, reason: 'alltime');
      expect(info.raw['name'], 'weekly-race');
    });

    test('submit: PUT …/scores/me with the exact body', () async {
      fake.answer(200, submitBody);
      final result = await client
          .board('weekly-race')
          .submit(1200, meta: '{"build":9007199254740993}');
      final request = fake.single;
      expect(request.method, 'PUT');
      expect(
        request.url.toString(),
        'https://doc.example/lb/weekly-race/scores/me',
      );
      expect(request.headers['content-type'], 'application/json');
      // `meta` is text, sent as a string: the integer past 2^53 survives.
      expect(
        request.body,
        '{"score":1200,"meta":"{\\"build\\":9007199254740993}"}',
      );
      expect(result.submitted, 1200);
      expect(result.periods, hasLength(2));
      expect(result.periods.first.bucket.period, 'alltime');
      expect(result.periods.first.score, 1500, reason: 'best kept the old');
      expect(result.periods.last.score, 1200);
      expect(result.periods.last.updatedAt, 1759300000);
    });

    test('submit: no meta omits the field; a server names the owner', () async {
      fake.answer(200, submitBody);
      await client
          .board('lb_01j9x3k2m4n5p6q7r8s9t0u1v2')
          .submit(-5, owner: owner32);
      final request = fake.single;
      expect(
        request.url.toString(),
        'https://doc.example/lb/lb_01j9x3k2m4n5p6q7r8s9t0u1v2/scores/$owner32',
      );
      expect(request.body, '{"score":-5}');
    });

    test('top: GET …/top with only the query that was set', () async {
      fake.answer(200, topBody);
      final page = await client.board('weekly-race').top();
      expect(
        fake.requests.single.url.toString(),
        'https://doc.example/lb/weekly-race/top',
      );
      expect(page.bucket.period, 'weekly');
      expect(page.bucket.periodKey, '2026-W40');
      expect(page.total, 3);
      expect(page.entries, hasLength(2));
      expect(page.entries.first.rank, 1);
      expect(page.entries.first.owner, owner32);
      expect(page.entries.first.score, 1500);
      expect(page.entries.first.meta, '{"build":9007199254740993}');
      expect(page.entries.last.meta, isNull);
      expect(page.entries.last.updatedAt, 1759290000);

      fake.answer(200, topBody);
      await client
          .board('weekly-race')
          .top(period: LbPeriod.weekly, limit: 100, offset: 1000);
      expect(
        fake.requests.last.url.toString(),
        'https://doc.example/lb/weekly-race/top?period=weekly&limit=100&offset=1000',
      );
    });

    test('score: GET …/scores/{owner}; a 404 is null', () async {
      fake.answer(200, scoreBody);
      final mine = await client.board('weekly-race').score();
      expect(
        fake.requests.single.url.toString(),
        'https://doc.example/lb/weekly-race/scores/me',
      );
      expect(mine?.owner, owner32);
      expect(mine?.score, 1500);
      expect(mine?.rank, 1);
      expect(mine?.total, 3);
      expect(mine?.bucket.period, 'alltime');
      expect(mine?.meta, isNull);
      expect(mine?.updatedAt, 1759300000);

      fake.answer(
        404,
        '{"error":{"code":"not_found","message":"score not found"}}',
      );
      final none = await client
          .board('weekly-race')
          .score(owner: owner32, period: LbPeriod.daily);
      expect(none, isNull);
      expect(
        fake.requests.last.url.toString(),
        'https://doc.example/lb/weekly-race/scores/$owner32?period=daily',
      );
    });

    test('deleteScore and clearPeriod', () async {
      fake.answer(204);
      expect(await client.board('weekly-race').deleteScore(owner32), isTrue);
      expect(fake.requests.single.method, 'DELETE');
      expect(
        fake.requests.single.url.toString(),
        'https://doc.example/lb/weekly-race/scores/$owner32',
      );
      fake.answer(
        404,
        '{"error":{"code":"not_found","message":"score not found"}}',
      );
      expect(await client.board('weekly-race').deleteScore(owner32), isFalse);

      fake.answer(200, clearBody);
      final cleared = await client
          .board('weekly-race')
          .clearPeriod(LbPeriod.weekly);
      expect(fake.requests.last.method, 'DELETE');
      expect(
        fake.requests.last.url.toString(),
        'https://doc.example/lb/weekly-race/periods/weekly',
      );
      expect(cleared.deleted, 500);
      expect(cleared.truncated, isTrue);
      expect(cleared.bucket.periodKey, '2026-W40');
    });

    test('a base URL with a path keeps it', () async {
      final c = LeaderboardClient(
        LeaderboardClientOptions(
          baseUrl: Uri.parse('https://doc.example/base/'),
          token: fixtureToken,
          client: fake,
        ),
      );
      fake.answer(200, infoBody);
      await c.board('b').info();
      expect(fake.single.url.toString(), 'https://doc.example/base/lb/b');
    });
  });

  group('refusals', () {
    test('status, code and reason; never the body', () async {
      fake.answer(
        409,
        '{"error":{"code":"conflict","message":"bucket full","details":{"reason":"board_full"}}}',
      );
      final full = await refused(() => client.board('b').submit(1));
      expect(full.status, 409);
      expect(full.code, 'conflict');
      expect(full.reason, 'board_full');
      expect(full.isBoardFull, isTrue);

      fake.answer(
        403,
        '{"error":{"code":"forbidden","message":"not allowed"}}',
      );
      final forbidden = await refused(() => client.board('b').submit(1));
      expect(forbidden.isForbidden, isTrue);
      expect(forbidden.reason, isNull);

      fake.answer(401, '');
      final unauthorized = await refused(() => client.board('b').info());
      expect(unauthorized.isUnauthorized, isTrue);
      expect(unauthorized.code, 'http_401');

      fake.answer(
        404,
        '{"error":{"code":"not_found","message":"leaderboard not found"}}',
      );
      final gone = await refused(() => client.board('b').info());
      expect(gone.isNotFound, isTrue);

      fake.answer(400, '{"error":{"code":"bad_request","message":"period"}}');
      final bad = await refused(() => client.board('b').top());
      expect(bad.isBadRequest, isTrue);

      // A code outside the grammar is dropped, not carried.
      fake.answer(
        503,
        '{"error":{"code":"Oops <html>","details":{"reason":"x y"}}}',
      );
      final odd = await refused(() => client.board('b').info());
      expect(odd.code, 'http_503');
      expect(odd.reason, isNull);
      expect(log.lines.join('\n'), isNot(contains('<html>')));
    });

    test('a malformed answer', () async {
      for (final body in <String>['', '[]', 'nope']) {
        fake.answer(200, body);
        final e = await refused(() => client.board('b').info());
        expect(
          e.code,
          LeaderboardException.malformedResponseCode,
          reason: body,
        );
        expect(e.status, 200);
      }
      fake.answer(200, 'x' * ((1 << 20) + 1));
      final big = await refused(() => client.board('b').top());
      expect(big.code, LeaderboardException.malformedResponseCode);
      fake.answerChunked(200, 'x' * ((1 << 20) + 1));
      final bigChunked = await refused(() => client.board('b').top());
      expect(bigChunked.code, LeaderboardException.malformedResponseCode);
    });

    test('network failures and the timeout abort the request', () async {
      fake.fail(http.ClientException('boom https://doc.example/secret'));
      final failed = await refused(() => client.board('b').info());
      expect(failed.status, 0);
      expect(failed.code, LeaderboardException.networkCode);
      fake.fail(const SocketException('refused'));
      expect((await refused(() => client.board('b').info())).code, 'network');
      fake.fail(ArgumentError('bad'));
      expect((await refused(() => client.board('b').info())).code, 'network');
      fake.fail(StateError('closed'));
      expect((await refused(() => client.board('b').info())).code, 'network');

      final quick = LeaderboardClient(
        LeaderboardClientOptions(
          baseUrl: Uri.parse('https://doc.example'),
          token: fixtureToken,
          client: fake,
          timeout: const Duration(milliseconds: 20),
        ),
      );
      fake.stallHeaders();
      expect((await refused(() => quick.board('b').info())).code, 'network');
      fake.stallBody(200);
      expect((await refused(() => quick.board('b').info())).code, 'network');
      // The abort trigger fires on a microtask after the timeout.
      await Future<void>.delayed(Duration.zero);
      expect(fake.aborted.where((a) => a), hasLength(2));
      final all = log.lines.join('\n');
      expect(all, isNot(contains('secret')));
      expect(
        log.lines.where(
          (l) =>
              l == '[warn] lb request failed {"method":"GET","route":"board"}',
        ),
        hasLength(4),
        reason:
            'every network failure warns with the kind only (the quick '
            'client has no logger)',
      );
    });
  });

  group('logging and lifetime', () {
    test('one debug line per request, warn on failure, never the token', () async {
      fake.answer(200, infoBody);
      await client.board('weekly-race').info();
      expect(
        log.lines.single,
        '[debug] lb request {"method":"GET","route":"board","status":200,"bytes":${infoBody.length}}',
      );
      // A refusal the server answered is the debug line with its status; the
      // warn line is for a request that got no answer.
      fake.answer(403, '{"error":{"code":"forbidden"}}');
      await refused(() => client.board('weekly-race').submit(1));
      expect(log.lines, hasLength(2));
      expect(
        log.lines[1],
        '[debug] lb request {"method":"PUT","route":"score","status":403,"bytes":30}',
      );
      // The positive control: the token went out...
      expect(
        fake.requests.first.headers['authorization'],
        contains(fixtureToken),
      );
      // ...and reached no line, nor did the board or the owner.
      final all = log.lines.join('\n');
      expect(all, isNot(contains(fixtureToken)));
      expect(all, isNot(contains('weekly-race')));
    });

    test(
      'close() closes an owned client once and leaves an injected one',
      () async {
        client.close();
        client.close();
        expect(fake.closed, isFalse);
        final owned = LeaderboardClient(
          LeaderboardClientOptions(
            baseUrl: Uri.parse('https://doc.example'),
            token: fixtureToken,
          ),
        );
        owned.close();
        owned.close();
        final e = await refused(() => owned.board('b').info());
        expect(e.code, LeaderboardException.networkCode);
      },
    );
  });
}
