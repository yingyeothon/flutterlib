import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

/// A raw client: a `dart:io` WebSocket with a frame queue.
final class RawClient {
  RawClient(this.socket) {
    socket.listen((data) => _frames.add(data), onDone: () => _done.complete());
  }

  static Future<RawClient> connect(
    FakeGateway gw,
    String token, {
    String channel = 'lobby_1',
    String? gameId,
  }) async => RawClient(
    await WebSocket.connect(
      gw.wsUrl
          .replace(
            queryParameters: <String, String>{
              'channel': channel,
              'gameId': ?gameId,
            },
          )
          .toString(),
      protocols: <String>['bearer', token],
    ),
  );

  final WebSocket socket;
  final StreamController<Object?> _frames = StreamController<Object?>();
  final Completer<void> _done = Completer<void>();
  late final StreamQueue _queue = StreamQueue(_frames.stream);

  /// The next frame that is not a `pos` batch: flushes run on their own
  /// timer, so a test that is not about them must not depend on where one
  /// lands.
  Future<JsonObject> next() async {
    while (true) {
      final frame = await nextFrame();
      if (frame['type'] != 'pos') return frame;
    }
  }

  /// The next frame, whatever it is.
  Future<JsonObject> nextFrame() async =>
      Json.decode(await _queue.next as String)! as JsonObject;

  /// The next `pos` batch with an entry for [userId], and that entry.
  Future<JsonObject> nextPosOf(String userId) async {
    while (true) {
      final frame = await nextFrame();
      if (frame['type'] != 'pos') continue;
      for (final p in frame['peers']! as List<Object?>) {
        if ((p! as JsonObject)['userId'] == userId) return p as JsonObject;
      }
    }
  }

  Future<void> get done => _done.future;

  void send(JsonObject frame) => socket.add(Json.encode(frame));

  Future<void> close() => socket.close(1000);
}

/// Minimal stream queue.
final class StreamQueue {
  StreamQueue(Stream<Object?> stream) {
    stream.listen((e) {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(e);
      } else {
        _buffer.add(e);
      }
    });
  }
  final List<Object?> _buffer = <Object?>[];
  final List<Completer<Object?>> _waiting = <Completer<Object?>>[];

  Future<Object?> get next {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<Object?>();
    _waiting.add(c);
    return c.future.timeout(const Duration(seconds: 5));
  }
}

void main() {
  late FakeGateway gw;
  setUp(
    () async => gw = await FakeGateway.start(
      options: const FakeGatewayOptions(tick: 20),
    ),
  );
  tearDown(() => gw.shutdown());

  test(
    'handshake: bearer echoed, hello first, user id from the token',
    () async {
      final a = await RawClient.connect(gw, 'alice');
      expect(a.socket.protocol, 'bearer');
      final hello = await a.next();
      expect(hello['type'], 'hello');
      expect(hello['userId'], 'alice');
      expect(hello['zone'], 'Zone001');
      expect(hello['tick'], 20);
      expect(hello['mapUrl'], gw.mapUrl.toString());
      expect((hello['aoi']! as JsonObject)['maxPeers'], 64);
      expect(hello.containsKey('partyId'), isFalse);
      expect(gw.lobbyUsers, {'alice'});
      await a.close();
    },
  );

  test('a JWT-shaped token yields its sub', () async {
    // Built at runtime so no JWT-shaped literal sits in the tree; the
    // signature is not checked, which is the point of the fake.
    final payload = base64Url.encode(utf8.encode('{"sub":"u42"}'));
    final token = 'header.$payload.sig';
    final a = await RawClient.connect(gw, token);
    expect((await a.next())['userId'], 'u42');
    await a.close();
  });

  test(
    'refuses a missing channel, a missing token and a rejected token',
    () async {
      Future<int> status(Uri uri, List<String> protocols) async {
        try {
          await WebSocket.connect(uri.toString(), protocols: protocols);
          return 101;
        } on WebSocketException catch (e) {
          return e.httpStatusCode ?? -1;
        }
      }

      expect(await status(gw.wsUrl, ['bearer', 't']), 400);
      expect(
        await status(gw.wsUrl.replace(queryParameters: {'channel': 'c'}), [
          'bearer',
        ]),
        401,
      );
      final strict = await FakeGateway.start(
        options: const FakeGatewayOptions(acceptedTokens: {'good'}),
      );
      addTearDown(strict.shutdown);
      expect(
        await status(strict.wsUrl.replace(queryParameters: {'channel': 'c'}), [
          'bearer',
          'bad',
        ]),
        401,
      );
      expect(
        await status(strict.wsUrl.replace(queryParameters: {'channel': 'c'}), [
          'bearer',
          'good',
        ]),
        101,
      );
    },
  );

  test('pos drives snapshot, enter, pos batches and leave', () async {
    final a = await RawClient.connect(gw, 'a');
    final b = await RawClient.connect(gw, 'b');
    await a.next();
    await b.next();
    a.send({'type': 'pos', 'zone': 'Z', 'x': 1, 'y': 2, 'dir': 'n'});
    final snapA = await a.next();
    // Like the gateway, a snapshot lists the others, never yourself; your
    // own position comes in the next flush.
    expect(snapA, {'type': 'snapshot', 'zone': 'Z', 'peers': <Object?>[]});
    expect(await a.nextPosOf('a'), {
      'userId': 'a',
      'x': 1.0,
      'y': 2.0,
      'dir': 'n',
    });
    b.send({'type': 'pos', 'zone': 'Z', 'x': 0, 'y': 0});
    final snapB = await b.next();
    expect(snapB['peers'], [
      {'userId': 'a', 'x': 1.0, 'y': 2.0, 'dir': 'n'},
    ]);
    expect(await a.next(), {
      'type': 'enter',
      'zone': 'Z',
      'userId': 'b',
      'x': 0.0,
      'y': 0.0,
    });
    a.send({'type': 'pos', 'zone': 'Z', 'x': 5, 'y': 5});
    Future<JsonObject> movedTo5(RawClient c) async {
      while (true) {
        final p = await c.nextPosOf('a');
        if (p['x'] == 5.0) return p;
      }
    }

    expect(await movedTo5(b), {'userId': 'a', 'x': 5.0, 'y': 5.0});
    expect(await movedTo5(a), {
      'userId': 'a',
      'x': 5.0,
      'y': 5.0,
    }, reason: 'the mover is included');
    a.send({'type': 'pos', 'zone': 'Y', 'x': 0, 'y': 0});
    expect(await b.next(), {'type': 'leave', 'zone': 'Z', 'userId': 'a'});
    expect((await a.next())['zone'], 'Y');
    await a.close();
    await b.close();
  });

  test('say and event route by scope with the documented refusals', () async {
    final a = await RawClient.connect(gw, 'a');
    final b = await RawClient.connect(gw, 'b');
    await a.next();
    await b.next();
    a.send({'type': 'say', 'scope': 'zone', 'text': 'x'});
    expect((await a.next())['code'], 'bad_zone');
    a.send({'type': 'say', 'scope': 'bogus', 'text': 'x'});
    expect((await a.next())['code'], 'bad_scope');
    a.send({'type': 'say', 'scope': 'party', 'text': 'x'});
    expect((await a.next())['code'], 'no_party');
    a.send({'type': 'say', 'scope': 'user', 'to': 'nobody', 'text': 'x'});
    expect((await a.next())['code'], 'unknown_user');
    a.send({'type': 'say', 'scope': 'user', 'to': 'b', 'text': 'x' * 1025});
    expect((await a.next())['code'], 'too_long');
    a.send({'type': 'say', 'scope': 'user', 'to': 'b', 'text': ''});
    expect((await a.next())['code'], 'too_long', reason: 'empty text');
    a.send({'type': 'say', 'scope': 'user', 'to': 'b', 'text': 'psst'});
    expect(await b.next(), {
      'type': 'say',
      'from': 'a',
      'scope': 'user',
      'to': 'b',
      'text': 'psst',
    });
    expect((await a.next())['text'], 'psst', reason: 'sender included');
    a.send({'type': 'pos', 'zone': 'Z', 'x': 0, 'y': 0});
    await a.next();
    a.send({
      'type': 'event',
      'scope': 'zone',
      'name': 'cast',
      'payload': {'k': 1},
      'to': 'ignored',
    });
    expect(await a.next(), {
      'type': 'event',
      'from': 'a',
      'scope': 'zone',
      'name': 'cast',
      'payload': {'k': 1},
    }, reason: '`to` is stripped unless the scope is user');
    a.send({'type': 'event', 'scope': 'zone', 'name': ''});
    expect((await a.next())['code'], 'bad_message', reason: 'empty name');
    a.send({'type': 'pos', 'zone': 'Z', 'x': 0, 'y': 0, 'dir': 'x' * 17});
    expect(
      (await a.next())['code'],
      'bad_message',
      reason: 'dir over 16 bytes',
    );
    a.send({'type': 'ping'});
    expect(await a.next(), {'type': 'pong'});
    a.send({'type': 'nope'});
    expect((await a.next())['code'], 'bad_message');
    expect(gw.received('a').length, 13);
    await a.close();
    await b.close();
  });

  test(
    'parties: create, invite, accept, decline, leave with omitempty',
    () async {
      final a = await RawClient.connect(gw, 'a');
      final b = await RawClient.connect(gw, 'b');
      final c = await RawClient.connect(gw, 'c');
      await a.next();
      await b.next();
      await c.next();
      a.send({'type': 'party.create'});
      final created = await a.next();
      expect(created['type'], 'party');
      expect(created['partyId'], 'pty_1');
      expect(created['leaderId'], 'a');
      expect(created.containsKey('invited'), isFalse, reason: 'omitempty');
      expect(created['max'], 4);
      a.send({'type': 'party.create'});
      expect((await a.next())['code'], 'already_in_party');
      b.send({'type': 'party.invite', 'userId': 'c'});
      expect((await b.next())['code'], 'no_party');
      a.send({'type': 'party.invite', 'userId': 'b'});
      expect(await b.next(), {
        'type': 'party.invite',
        'partyId': 'pty_1',
        'from': 'a',
      });
      expect((await a.next())['invited'], ['b']);
      a.send({'type': 'party.invite', 'userId': 'c'});
      await c.next();
      await a.next();
      c.send({'type': 'party.decline', 'partyId': 'pty_1'});
      expect(await a.next(), {
        'type': 'party.declined',
        'partyId': 'pty_1',
        'userId': 'c',
      });
      expect((await a.next())['invited'], ['b']);
      b.send({'type': 'party.accept', 'partyId': 'pty_1'});
      final rosterA = await a.next();
      final rosterB = await b.next();
      expect(rosterA, rosterB);
      expect(rosterA['members'], [
        {'userId': 'a', 'online': true},
        {'userId': 'b', 'online': true},
      ]);
      expect(rosterA.containsKey('invited'), isFalse);
      b.send({'type': 'party.accept', 'partyId': 'pty_1'});
      expect((await b.next())['code'], 'not_invited');
      b.send({'type': 'party.accept', 'partyId': 'pty_x'});
      expect((await b.next())['code'], 'unknown_party');
      b.send({'type': 'party.invite', 'userId': 'c'});
      expect((await b.next())['code'], 'not_leader');
      a.send({'type': 'party.leave'});
      expect(await a.next(), {
        'type': 'party',
        'partyId': '',
        'members': <Object?>[],
      });
      final promoted = await b.next();
      expect(promoted['leaderId'], 'b');
      b.send({'type': 'party.list'});
      expect((await b.next())['partyId'], 'pty_1');
      a.send({'type': 'party.list'});
      expect((await a.next())['partyId'], '');
      await a.close();
      await b.close();
      await c.close();
    },
  );

  test('a newer socket replaces the older with 4000', () async {
    final first = await RawClient.connect(gw, 'a');
    await first.next();
    final second = await RawClient.connect(gw, 'a');
    await second.next();
    await first.done;
    expect(first.socket.closeCode, 4000);
    expect(gw.lobbyUsers, {'a'});
    await second.close();
  });

  test('closeUser, sendRaw, sendBinary and the inbound caps', () async {
    final a = await RawClient.connect(gw, 'a');
    await a.next();
    gw.sendRaw('a', 'not json');
    expect(await a._queue.next, 'not json');
    gw.sendBinary('a', [1, 2, 3]);
    expect(await a._queue.next, [1, 2, 3]);
    await gw.closeUser('a', 4002, reason: 'idle');
    await a.done;
    expect(a.socket.closeCode, 4002);
    final b = await RawClient.connect(gw, 'b');
    await b.next();
    b.socket.add([0]);
    await b.done;
    expect(b.socket.closeCode, 1003);
    final c = await RawClient.connect(gw, 'c');
    await c.next();
    c.socket.add('"${'x' * (16 * 1024)}"');
    await c.done;
    expect(c.socket.closeCode, 1009);
  });

  test('map.json and livez are served over HTTP', () async {
    final client = HttpClient();
    final response = await (await client.getUrl(gw.mapUrl)).close();
    expect(response.statusCode, 200);
    final body = await response.transform<String>(utf8.decoder).join();
    expect(Json.decode(body), {
      'name': 'fake',
      'zones': ['Zone001', 'Zone002'],
    });
    final live = await (await client.getUrl(
      gw.wsUrl.replace(scheme: 'http', path: '/livez'),
    )).close();
    expect(live.statusCode, 200);
    client.close();
  });

  test('q: welcome, echo, reserved types, custom handler, abort', () async {
    final a = await RawClient.connect(gw, 'a', channel: 'q_1', gameId: 'g1');
    expect((await a.next())['type'], 'welcome');
    a.send({'type': 'move', 'dx': 1});
    expect(await a.next(), {
      'type': 'echo',
      'of': {'type': 'move', 'dx': 1},
    });
    a.send({'type': 'enter'});
    expect((await a.next())['code'], 'reserved_type');
    a.socket.add('[1]');
    expect((await a.next())['code'], 'bad_message');
    expect(gw.gameMembers, {
      'g1': {'a'},
    });
    await gw.closeUser('a', 4001, gameId: 'g1');
    await a.done;
    expect(a.socket.closeCode, 4001);
    // The server side observes its own done a moment later.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gw.gameMembers, isEmpty);

    final scripted = await FakeGateway.start(
      options: FakeGatewayOptions(
        onGameFrame: (s, f) => s.broadcast({'type': 'seen', 'by': s.userId}),
      ),
    );
    addTearDown(scripted.shutdown);
    final x = await RawClient.connect(
      scripted,
      'x',
      channel: 'q_1',
      gameId: 'g2',
    );
    final y = await RawClient.connect(
      scripted,
      'y',
      channel: 'q_1',
      gameId: 'g2',
    );
    await x.next();
    await y.next();
    x.send({'type': 'hi'});
    expect(await y.next(), {'type': 'seen', 'by': 'x'});
    expect(await x.next(), {'type': 'seen', 'by': 'x'});
  });

  test('a reconnect resumes the retained zone and the party', () async {
    final a = await RawClient.connect(gw, 'a');
    await a.next();
    a.send({'type': 'pos', 'zone': 'Z', 'x': 1, 'y': 1});
    await a.next();
    a.send({'type': 'party.create'});
    await a.next();
    await a.close();
    final again = await RawClient.connect(gw, 'a');
    final hello = await again.next();
    expect(hello['partyId'], 'pty_1');
    final snapshot = await again.next();
    expect(snapshot['type'], 'snapshot');
    expect(snapshot['zone'], 'Z');
    expect((await again.next())['type'], 'party');
    await again.close();
  });

  group('fidelity', () {
    Future<int> status(
      FakeGateway g,
      Map<String, String> query,
      String token,
    ) async {
      try {
        final socket = await WebSocket.connect(
          g.wsUrl.replace(queryParameters: query).toString(),
          protocols: <String>['bearer', token],
        );
        await socket.close(1000);
        return 101;
      } on WebSocketException catch (e) {
        return e.httpStatusCode ?? -1;
      }
    }

    test('handshake: unknown channel 404, game membership 403, injected '
        'statuses before any check', () async {
      final strict = await FakeGateway.start(
        options: const FakeGatewayOptions(
          channels: {'lobby_1', 'q_1'},
          games: {
            'g1': {'a'},
          },
        ),
      );
      addTearDown(strict.shutdown);
      expect(await status(strict, {'channel': 'lobby_2'}, 'a'), 404);
      // A missing bearer is 401 before the channel lookup's 404.
      try {
        await WebSocket.connect(
          strict.wsUrl
              .replace(queryParameters: {'channel': 'lobby_2'})
              .toString(),
        );
        fail('connected without a bearer');
      } on WebSocketException catch (e) {
        expect(e.httpStatusCode, 401);
      }
      expect(await status(strict, {'channel': 'lobby_1'}, 'a'), 101);
      // One code for an unknown game and for a non-member.
      expect(
        await status(strict, {'channel': 'q_1', 'gameId': 'g9'}, 'a'),
        403,
      );
      expect(
        await status(strict, {'channel': 'q_1', 'gameId': 'g1'}, 'b'),
        403,
      );
      expect(
        await status(strict, {'channel': 'q_1', 'gameId': 'g1'}, 'a'),
        101,
      );
      strict.refuseHandshakes(410, count: 2);
      expect(await status(strict, {'channel': 'lobby_1'}, 'a'), 410);
      expect(await status(strict, {}, 'a'), 410, reason: 'before the 400');
      expect(await status(strict, {'channel': 'lobby_1'}, 'a'), 101);
      for (final code in <int>[429, 502, 503]) {
        strict.refuseHandshakes(code);
        expect(await status(strict, {'channel': 'lobby_1'}, 'a'), code);
      }
    });

    test('every party type is refused when party is off', () async {
      final off = await FakeGateway.start(
        options: const FakeGatewayOptions(
          capabilities: <String, Object?>{'pos': true, 'party': false},
        ),
      );
      addTearDown(off.shutdown);
      final a = await RawClient.connect(off, 'a');
      await a.next();
      for (final type in <String>[
        'party.create',
        'party.invite',
        'party.accept',
        'party.decline',
        'party.leave',
        'party.list',
      ]) {
        a.send({'type': type, 'userId': 'b', 'partyId': 'p'});
        final refusal = await a.next();
        expect(refusal['code'], 'capability_off', reason: type);
      }
      await a.close();
    });

    test('a snapshot shows the maxPeers nearest others, by user id', () async {
      final few = await FakeGateway.start(
        options: const FakeGatewayOptions(maxPeers: 2),
      );
      addTearDown(few.shutdown);
      final others = <RawClient>[];
      for (final (id, x) in <(String, int)>[
        ('d', 9),
        ('c', 1),
        ('b', 1),
        ('a', 5),
      ]) {
        final c = await RawClient.connect(few, id);
        await c.next();
        c.send({'type': 'pos', 'zone': 'Z', 'x': x, 'y': 0});
        await c.next();
        others.add(c);
      }
      final me = await RawClient.connect(few, 'me');
      await me.next();
      me.send({'type': 'pos', 'zone': 'Z', 'x': 0, 'y': 0});
      final snapshot = await me.next();
      // b and c tie at distance 1; a (5) and d (9) are cut.
      expect(
        (snapshot['peers']! as List<Object?>).map(
          (p) => (p! as JsonObject)['userId'],
        ),
        ['b', 'c'],
      );
      for (final c in [...others, me]) {
        await c.close();
      }
    });

    test('maxMoveDelta holds inside a zone, from a retained position too; '
        'a zone change is free', () async {
      final strict = await FakeGateway.start(
        options: const FakeGatewayOptions(maxMoveDelta: 3),
      );
      addTearDown(strict.shutdown);
      final a = await RawClient.connect(strict, 'a');
      await a.next();
      a.send({'type': 'pos', 'zone': 'Z', 'x': 10, 'y': 10});
      expect((await a.next())['type'], 'snapshot');
      a.send({'type': 'pos', 'zone': 'Z', 'x': 13, 'y': 7});
      a.send({'type': 'pos', 'zone': 'Z', 'x': 17, 'y': 7});
      expect((await a.next())['code'], 'move_too_far');
      await a.close();
      // A new socket resumes (13, 7) in Z: a spawn at (0, 0) is refused.
      final again = await RawClient.connect(strict, 'a');
      await again.next();
      expect((await again.next())['zone'], 'Z');
      expect(await again.nextPosOf('a'), {'userId': 'a', 'x': 13.0, 'y': 7.0});
      again.send({'type': 'pos', 'zone': 'Z', 'x': 0, 'y': 0});
      expect((await again.next())['code'], 'move_too_far');
      again.send({'type': 'pos', 'zone': 'Y', 'x': 0, 'y': 0});
      expect((await again.next())['type'], 'snapshot');
      await again.close();
    });

    test('an event payload is capped at 8 KB (too_long)', () async {
      final a = await RawClient.connect(gw, 'a');
      await a.next();
      a.send({'type': 'pos', 'zone': 'Z', 'x': 0, 'y': 0});
      await a.next();
      // A JSON string of n characters encodes to n + 2 bytes.
      a.send({
        'type': 'event',
        'scope': 'zone',
        'name': 'n',
        'payload': 'x' * 8190,
      });
      expect((await a.next())['type'], 'event');
      a.send({
        'type': 'event',
        'scope': 'zone',
        'name': 'n',
        'payload': 'x' * 8191,
      });
      expect((await a.next())['code'], 'too_long');
      await a.close();
    });

    test('an outbound frame over 32 KB becomes frame_too_large', () async {
      final big = await FakeGateway.start(
        options: FakeGatewayOptions(
          // `{"type":"big","s":""}` is 21 bytes.
          onGameFrame: (s, f) => s.send({
            'type': 'big',
            's': 'x' * ((f! as JsonObject)['n']! as int),
          }),
        ),
      );
      addTearDown(big.shutdown);
      final a = await RawClient.connect(big, 'a', channel: 'q_1', gameId: 'g');
      await a.next();
      a.send({'type': 'give', 'n': 32768 - 21});
      expect((await a.next())['type'], 'big');
      a.send({'type': 'give', 'n': 32768 - 20});
      final refusal = await a.next();
      expect(refusal['type'], 'error');
      expect(refusal['code'], 'frame_too_large');
      await a.close();
    });

    test('a stalled actor dies past depth 200 with 4001', () async {
      final a = await RawClient.connect(gw, 'a', channel: 'q_1', gameId: 'g');
      await a.next();
      gw.stallGame('g');
      for (var i = 0; i < 200; i++) {
        a.send({'type': 'tick'});
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gw.gameMembers, {
        'g': {'a'},
      });
      a.send({'type': 'tick'});
      await a.done.timeout(const Duration(seconds: 5));
      expect(a.socket.closeCode, 4001);
      expect(gw.gameMembers, isEmpty);
    });

    test(
      'a leave counts toward the depth; a restarted game dies again',
      () async {
        final a = await RawClient.connect(gw, 'a', channel: 'q_1', gameId: 'g');
        final b = await RawClient.connect(gw, 'b', channel: 'q_1', gameId: 'g');
        await a.next();
        await b.next();
        gw.stallGame('g');
        for (var i = 0; i < 200; i++) {
          a.send({'type': 'tick'});
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(gw.gameMembers['g'], {'a', 'b'});
        // b's leave is push 201.
        await b.close();
        await a.done.timeout(const Duration(seconds: 5));
        expect(a.socket.closeCode, 4001);
        expect(gw.gameMembers, isEmpty);

        // The same id starts a new game on a fresh queue; the actor is still
        // dead, so it takes 201 more pushes (the enter is one) to abort.
        final again = await RawClient.connect(
          gw,
          'a',
          channel: 'q_1',
          gameId: 'g',
        );
        for (var i = 0; i < 199; i++) {
          again.send({'type': 'tick'});
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(gw.gameMembers['g'], {'a'});
        again.send({'type': 'tick'});
        again.send({'type': 'tick'});
        await again.done.timeout(const Duration(seconds: 5));
        expect(again.socket.closeCode, 4001);
      },
    );

    test('a stalled actor dies over depth 20 after more than 5 s', () async {
      var now = DateTime.utc(2026);
      final clocked = await FakeGateway.start(
        options: FakeGatewayOptions(clock: () => now),
      );
      addTearDown(clocked.shutdown);
      final a = await RawClient.connect(
        clocked,
        'a',
        channel: 'q_1',
        gameId: 'g',
      );
      await a.next();
      clocked.stallGame('g');
      for (var i = 0; i < 21; i++) {
        a.send({'type': 'tick'});
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      now = now.add(const Duration(seconds: 5));
      a.send({'type': 'tick'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(clocked.gameMembers, contains('g'), reason: '5 s is not more');
      now = now.add(const Duration(milliseconds: 1));
      a.send({'type': 'tick'});
      await a.done.timeout(const Duration(seconds: 5));
      expect(a.socket.closeCode, 4001);
    });

    test(
      'a held reader loses pos batches first, then closes with 4005',
      () async {
        // A slow tick, so each flush lands where the test puts it.
        final slow = await FakeGateway.start(
          options: const FakeGatewayOptions(tick: 200),
        );
        addTearDown(slow.shutdown);
        final a = await RawClient.connect(slow, 'a');
        final b = await RawClient.connect(slow, 'b');
        await a.next();
        await b.next();
        a.send({'type': 'pos', 'zone': 'Z', 'x': 0, 'y': 0});
        await a.next();
        b.send({'type': 'pos', 'zone': 'Z', 'x': 1, 'y': 0});
        await b.next();
        expect((await a.next())['type'], 'enter');
        // The entry flushes land; a pong then drains a's socket.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        a.send({'type': 'ping'});
        while ((await a.nextFrame())['type'] != 'pong') {}

        Future<List<JsonObject>> heldRound(double x, int says) async {
          slow.holdOutbound('a');
          b.send({'type': 'pos', 'zone': 'Z', 'x': x, 'y': 0});
          // One flush puts a `pos` batch in a's queue.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          for (var i = 0; i < says; i++) {
            b.send({'type': 'say', 'scope': 'zone', 'text': 's$i'});
          }
          b.send({'type': 'ping'});
          while ((await b.nextFrame())['type'] != 'pong') {}
          slow.releaseOutbound('a');
          return <JsonObject>[
            for (var i = 0; i < 256; i++) await a.nextFrame(),
          ];
        }

        // Room for all: the batch is kept, first, in order.
        final roomy = await heldRound(2, 255);
        expect(roomy.first['type'], 'pos');
        expect((roomy.first['peers']! as List<Object?>).single, {
          'userId': 'b',
          'x': 2.0,
          'y': 0.0,
        });
        expect(roomy.skip(1).map((f) => f['type']).toSet(), {'say'});
        // One frame too many: the batch, the only droppable, goes.
        final full = await heldRound(3, 256);
        expect(full.map((f) => f['type']).toSet(), {
          'say',
        }, reason: 'the pos batch was dropped to make room');
        expect(full.first['text'], 's0');
        expect(full.last['text'], 's255');

        slow.holdOutbound('a');
        for (var i = 0; i < 257; i++) {
          b.send({'type': 'say', 'scope': 'zone', 'text': 't$i'});
        }
        await a.done.timeout(const Duration(seconds: 5));
        expect(a.socket.closeCode, 4005);
        await b.close();
      },
    );
  });
}
