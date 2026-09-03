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

  Future<JsonObject> next() async =>
      Json.decode(await _queue.next as String)! as JsonObject;

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
    expect(snapA, {
      'type': 'snapshot',
      'zone': 'Z',
      'peers': [
        {'userId': 'a', 'x': 1.0, 'y': 2.0, 'dir': 'n'},
      ],
    });
    b.send({'type': 'pos', 'zone': 'Z', 'x': 0, 'y': 0});
    final snapB = await b.next();
    expect((snapB['peers']! as List).length, 2);
    expect(await a.next(), {
      'type': 'enter',
      'zone': 'Z',
      'userId': 'b',
      'x': 0.0,
      'y': 0.0,
    });
    a.send({'type': 'pos', 'zone': 'Z', 'x': 5, 'y': 5});
    final batch = await b.next();
    expect(batch['type'], 'pos');
    expect(batch['peers'], [
      {'userId': 'a', 'x': 5.0, 'y': 5.0},
    ]);
    expect((await a.next())['type'], 'pos', reason: 'the mover is included');
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
    });
    expect(await a.next(), {
      'type': 'event',
      'from': 'a',
      'scope': 'zone',
      'name': 'cast',
      'payload': {'k': 1},
    });
    a.send({'type': 'ping'});
    expect(await a.next(), {'type': 'pong'});
    a.send({'type': 'nope'});
    expect((await a.next())['code'], 'bad_message');
    expect(gw.received('a').length, 10);
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
    expect((await again.next())['type'], 'party');
    final snapshot = await again.next();
    expect(snapshot['type'], 'snapshot');
    expect(snapshot['zone'], 'Z');
    await again.close();
  });
}
