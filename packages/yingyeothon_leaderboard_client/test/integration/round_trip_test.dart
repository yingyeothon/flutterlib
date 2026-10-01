// The client over a real `package:http` client against a loopback server:
// the fake gateway's `/lb/*` routes, and, when `YYT_KV_BASE_URL`,
// `YYT_KV_TOKEN` and `YYT_LB_BOARD` are set, the dev state stack too (a
// `submit: owner` board named by `YYT_LB_BOARD`). No value is ever printed.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_leaderboard_client/yingyeothon_leaderboard_client.dart';

Future<T> soon<T>(Future<T> f) => f.timeout(const Duration(seconds: 10));

/// The guide's case against any server that follows the contract: a player
/// submits its own score to a `submit: owner` board, reads the page and its
/// own rank.
Future<void> walk(LeaderboardClient client, String boardRef) async {
  final board = client.board(boardRef);
  final info = await soon(board.info());
  expect(info.submit, LbSubmit.owner);
  expect(info.periods, isNotEmpty);
  expect(info.periods.first.period, isIn(LbRules.periods));

  final result = await soon(board.submit(100, meta: '{"lap":1}'));
  expect(result.submitted, 100);
  expect(
    result.periods.map((p) => p.bucket.period),
    info.periods.map((b) => b.period),
  );

  final mine = await soon(board.score());
  expect(mine, isNotNull);
  expect(mine!.score, isNonNegative);
  expect(mine.rank, greaterThanOrEqualTo(1));
  expect(mine.total, greaterThanOrEqualTo(1));
  expect(mine.bucket.period, info.periods.first.period);

  final page = await soon(board.top(limit: 100));
  expect(page.total, mine.total);
  expect(page.entries.any((e) => e.owner == mine.owner), isTrue);
  expect(page.entries.map((e) => e.rank), isNotEmpty);
  final first = page.entries.first;
  expect(first.rank, 1);
  // Ranked: no later row is better than the first.
  for (final e in page.entries) {
    expect(
      info.order == LbOrder.asc
          ? e.score >= first.score
          : e.score <= first.score,
      isTrue,
    );
  }
}

void main() {
  test('round trip against the fake gateway', () async {
    final gw = await FakeGateway.start(
      options: const FakeGatewayOptions(
        leaderboards: <FakeLeaderboard>[
          FakeLeaderboard(
            name: 'race',
            periods: <String>['alltime', 'weekly'],
            scores: <String, int>{'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb': 50},
          ),
        ],
      ),
    );
    final client = LeaderboardClient(
      LeaderboardClientOptions(baseUrl: gw.kvUrl, token: 'alice'),
    );
    try {
      await walk(client, 'race');
      expect(gw.lb.scoreOf('race', 'alice'), 100);
      // The whole board page, then the server's clear.
      final server = LeaderboardClient(
        LeaderboardClientOptions(
          baseUrl: gw.kvUrl,
          token: 'yds.auth_0123456789abcdef.k',
        ),
      );
      try {
        expect(await soon(server.board('race').deleteScore('b' * 32)), isTrue);
        final cleared = await soon(server.board('race').clearPeriod('alltime'));
        expect(cleared.deleted, 1);
        expect(await soon(client.board('race').score()), isNull);
      } finally {
        server.close();
      }
    } finally {
      client.close();
      await gw.shutdown();
    }
  });

  test('round trip against dev', () async {
    final baseUrl = Platform.environment['YYT_KV_BASE_URL'];
    final token = Platform.environment['YYT_KV_TOKEN'];
    final boardRef = Platform.environment['YYT_LB_BOARD'];
    if (baseUrl == null || token == null || boardRef == null) {
      markTestSkipped('YYT_KV_BASE_URL, YYT_KV_TOKEN, YYT_LB_BOARD not set');
      return;
    }
    // tryParse: a FormatException would quote the operator's URL.
    final base = Uri.tryParse(baseUrl);
    if (base == null) fail('YYT_KV_BASE_URL is not a URL');
    final client = LeaderboardClient(
      LeaderboardClientOptions(baseUrl: base, token: token),
    );
    try {
      await walk(client, boardRef);
    } finally {
      client.close();
    }
  });
}
