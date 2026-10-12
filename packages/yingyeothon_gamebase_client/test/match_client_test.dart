import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import 'support/fake_http_client.dart';
import 'support/fake_web_socket.dart';

// service/services/match/src/matcher.ts: matched payload; deferred.ts: confirmed.
const matched =
    '{"type":"matched","matchId":"m1","partial":false,"result":null,"members":[{"userId":"alice","skill":4}],"extra":true}';
const tickets = [
  {'state': 'waiting', 'position': 1, 'waited': 0},
  {
    'state': 'proposed',
    'matchId': 'm1',
    'acceptBy': 1234,
    'accepted': false,
    'partial': false,
  },
  {
    'state': 'confirmed',
    'matchId': 'm1',
    'partial': false,
    'result': null,
    'members': [
      {'userId': 'a'},
    ],
  },
  {'state': 'expired', 'reason': 'wait'},
  {'state': 'declined', 'matchId': 'm1'},
  {'state': 'failed', 'reason': 'callback'},
];
void main() {
  group('deferred', () {
    late FakeHttp http;
    late DeferredMatchClient client;
    setUp(() {
      http = FakeHttp();
      client = DeferredMatchClient(
        DeferredMatchClientOptions(
          apiBase: Uri.parse('http://fake/base'),
          channelId: 'ch_match',
          token: 'fixture',
          client: http,
        ),
      );
    });
    tearDown(() => client.close());
    test(
      'all tickets tolerate extensions, retaining a shared result',
      () async {
        for (final ticket in tickets) {
          http.answer(200, jsonEncode({...ticket, 'future': true}));
          final parsed = await client.status();
          expect(parsed!.state, ticket['state']);
          expect(parsed.raw['future'], true);
          if (parsed.state == 'confirmed') {
            expect(parsed.confirmed!.members.single.userId, 'a');
          }
          if (parsed.state == 'proposed') {
            expect(parsed.acceptBy, 1234);
            expect(parsed.accepted, false);
            expect(parsed.matchId, 'm1');
          }
        }
        expect(http.requests.every((r) => !r.followRedirects), true);
      },
    );
    test('commands send methods, authorization and routes exactly', () async {
      for (final action in [client.submit, client.accept, client.decline]) {
        http.answer(200, jsonEncode(tickets.first));
        await action();
      }
      http.answer(204);
      await client.cancel();
      expect(http.requests.map((r) => r.method), [
        'POST',
        'POST',
        'POST',
        'DELETE',
      ]);
      expect(http.requests.map((r) => r.url.path), [
        '/base/m/ch_match/ticket',
        '/base/m/ch_match/accept',
        '/base/m/ch_match/decline',
        '/base/m/ch_match/ticket',
      ]);
      expect(
        http.requests.every(
          (r) => r.headers['authorization'] == 'Bearer fixture',
        ),
        true,
      );
      expect(http.closed, false);
      http.answer(404);
      expect(await client.status(), null);
    });
    test('cooldown and confirming failures preserve only safe fields', () async {
      // service/services/match/src/tickets.ts: AppError reason and retryAfter.
      http.answer(
        429,
        '{"error":{"code":"rate_limited","details":{"reason":"cooldown","retryAfter":5}}}',
      );
      await expectLater(
        client.submit(),
        throwsA(
          isA<MatchException>()
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 5),
              )
              .having((e) => e.reason, 'reason', 'cooldown'),
        ),
      );
      for (final status in [401, 409, 429, 503]) {
        http.answer(
          status,
          '{"error":{"code":"http://secret","details":{"reason":"http://secret","retryAfter":-1}}}',
        );
        await expectLater(
          client.submit(),
          throwsA(
            isA<MatchException>()
                .having((e) => e.code, 'code', 'http_$status')
                .having((e) => e.reason, 'reason', null)
                .having((e) => e.retryAfter, 'retry', null)
                .having(
                  (e) => e.toString(),
                  'diagnostic',
                  'MatchException(http_$status, $status)',
                ),
          ),
        );
      }
    });
    test(
      'malformed tickets do not silently become empty successful values',
      () async {
        for (final body in [
          'oops',
          'null',
          '{}',
          '{"state":"new"}',
          ...tickets.map(
            (t) => jsonEncode({
              ...t,
              if (t['state'] == 'waiting') 'position': null,
              if (t['state'] == 'proposed') 'acceptBy': null,
              if (t['state'] == 'confirmed') 'members': [null],
              if (t['state'] == 'expired' || t['state'] == 'failed')
                'reason': null,
              if (t['state'] == 'declined') 'matchId': null,
            }),
          ),
        ]) {
          http.answer(200, body);
          await expectLater(
            client.status(),
            throwsA(
              isA<MatchException>().having(
                (e) => e.code,
                'code',
                'malformed_response',
              ),
            ),
          );
        }
        http.answer(
          200,
          '{"state":"confirmed","matchId":"m","partial":false,"members":[]}',
        );
        await expectLater(client.status(), throwsA(isA<MatchException>()));
      },
    );
    test('transport errors, bounded bodies and closes are safe', () async {
      for (final error in [
        const SocketException('sensitive'),
        FormatException('sensitive'),
        ArgumentError('sensitive'),
        StateError('sensitive'),
      ]) {
        http.fail(error);
        await expectLater(client.submit(), throwsA(isA<MatchException>()));
      }
      http.answer(200, 'x' * ((1 << 20) + 1));
      await expectLater(client.submit(), throwsA(isA<MatchException>()));
      http.answerChunked(200, 'x' * ((1 << 20) + 1));
      await expectLater(client.submit(), throwsA(isA<MatchException>()));
      client.close();
      expect(http.closed, false);
      await expectLater(client.submit(), throwsStateError);
    });
    test('headers and drip-fed bodies share one deadline', () {
      fakeAsync((async) {
        final h = FakeHttp()..stallHeaders();
        final c = DeferredMatchClient(
          DeferredMatchClientOptions(
            apiBase: Uri.parse('http://fake'),
            channelId: 'ch',
            token: 't',
            client: h,
            timeout: const Duration(seconds: 1),
          ),
        );
        Object? error;
        unawaited(
          c.submit().catchError((Object e) {
            error = e;
            return MatchTicket(state: 'failed', raw: {});
          }),
        );
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(error, isA<MatchException>());
        expect(h.aborted, [true]);
        c.close();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
  test('constructor guards never quote unsafe credentials or URLs', () {
    for (final base in [
      'relative',
      'file:///x',
      'http://u:p@host',
      'http://host/?q=1',
    ]) {
      expect(
        () => DeferredMatchClient(
          DeferredMatchClientOptions(
            apiBase: Uri.parse(base),
            channelId: 'ch',
            token: 't',
          ),
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => DeferredMatchClient(
        DeferredMatchClientOptions(
          apiBase: Uri.parse('http://fake'),
          channelId: '../',
          token: 't',
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => DeferredMatchClient(
        DeferredMatchClientOptions(
          apiBase: Uri.parse('http://fake'),
          channelId: 'ch',
          token: 'bad\n',
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => DeferredMatchClient(
        DeferredMatchClientOptions(
          apiBase: Uri.parse('http://fake'),
          channelId: 'ch',
          token: 't',
          timeout: Duration.zero,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => DeferredMatchClient(
        DeferredMatchClientOptions(
          apiBase: Uri.parse('http://fake'),
          channelId: 'ch',
          token: 't',
          ticketUrl: Uri.parse('http://other/m/ch/ticket'),
        ),
      ),
      throwsArgumentError,
    );
    final owned = DeferredMatchClient(
      DeferredMatchClientOptions(
        apiBase: Uri.parse('http://fake'),
        channelId: 'ch',
        token: 't',
      ),
    );
    owned.close();
    owned.close();
  });
  group('live', () {
    late FakeWebSocketFactory sockets;
    late LiveMatchClient client;
    setUp(() {
      sockets = FakeWebSocketFactory();
      client = LiveMatchClient(
        LiveMatchClientOptions(
          url: Uri.parse('ws://fake'),
          channelId: 'ch',
          token: 't',
          webSocketFactory: sockets,
          timeout: const Duration(seconds: 3),
        ),
      );
    });
    tearDown(() => client.close());
    test(
      'matched members retain extensions; terminal message closes socket',
      () async {
        final task = client.find();
        expect(identical(client.find(), task), true);
        final socket = sockets.latest;
        socket.serverOpen();
        socket.serverSendRaw(matched);
        final result = await task;
        expect(result.members.single.raw['skill'], 4);
        expect(result.raw['extra'], true);
        expect(socket.clientCloseCode, 1000);
        expect(socket.request.url.queryParameters, {'channel': 'ch'});
        expect(socket.request.subprotocols, ['bearer', 't']);
        expect(
          () => result.members.add(MatchMember('b', {})),
          throwsUnsupportedError,
        );
      },
    );
    test('cancel is settled and a new find may start', () async {
      final task = client.find();
      final failure = expectLater(
        task,
        throwsA(
          isA<MatchException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      client.cancel();
      await failure;
      final second = client.find();
      sockets.latest.serverSendRaw(matched);
      await second;
      await client.close();
      expect(client.find, throwsStateError);
    });
    test('refusal and malformed paths settle once', () async {
      for (final text in [
        'bad',
        '[]',
        '{}',
        '{"type":"matched"}',
        '{"type":"matched","matchId":"m","partial":false,"result":null,"members":[{}]}',
        '{"type":"failed","reason":"timeout"}',
        '{"type":"replaced"}',
      ]) {
        final task = client.find();
        final assertion = expectLater(task, throwsA(isA<MatchException>()));
        sockets.latest.serverSendRaw(text);
        await assertion;
      }
      for (final event in ['protocol', 'binary', 'close']) {
        final task = client.find();
        final assertion = expectLater(task, throwsA(isA<MatchException>()));
        if (event == 'protocol') sockets.latest.serverOpen('wrong');
        if (event == 'binary') sockets.latest.serverSendBinary();
        if (event == 'close') sockets.latest.serverError();
        await assertion;
      }
    });
    test(
      'unknown frame ignored, timeout and terminal success cancel timers',
      () {
        fakeAsync((async) {
          Object? error;
          unawaited(
            client.find().catchError((Object e) {
              error = e;
              return MatchResult(
                matchId: 'x',
                partial: false,
                result: null,
                members: [],
                raw: {},
              );
            }),
          );
          sockets.latest.serverSendRaw('{"type":"future"}');
          async.elapse(const Duration(seconds: 3));
          async.flushMicrotasks();
          expect(error, isA<MatchException>());
          expect(async.pendingTimers, isEmpty);
          unawaited(client.find());
          sockets.latest.serverSendRaw(matched);
          async.flushMicrotasks();
          expect(async.pendingTimers, isEmpty);
        });
      },
    );
  });
  test('presence batches validated player ids using bearer HTTP', () async {
    final h = FakeHttp();
    final c = GatewayPresenceClient(
      GatewayPresenceClientOptions(
        baseUrl: Uri.parse('http://fake'),
        channelId: 'ch',
        token: 't',
        client: h,
      ),
    );
    final id = 'a' * 32;
    h.answer(
      200,
      jsonEncode({
        'type': 'presence',
        'users': [
          {'userId': id, 'online': true},
        ],
      }),
    );
    expect((await c.users([id])).single.online, true);
    expect(h.single.url.queryParameters, {'channel': 'ch', 'users': id});
    expect(await c.users([]), isEmpty);
    await expectLater(c.users(['wrong']), throwsArgumentError);
    await expectLater(c.users(List.filled(51, id)), throwsArgumentError);
    for (final body in ['{}', '{"users":[{}]}']) {
      h.answer(200, body);
      await expectLater(c.users([id]), throwsA(isA<MatchException>()));
    }
    c.close();
  });
}
