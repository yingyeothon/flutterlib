import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import 'support/harness.dart';

void main() {
  for (final code in <int>[4002, 4005, 1001, 1006, 1011, 1234]) {
    test('close $code reconnects with backoff and an empty peer map', () {
      fakeAsync((async) {
        final h = LobbyHarness(async)..connect();
        h.openAndHello();
        h.socket.serverSend(<String, Object?>{
          'type': 'snapshot',
          'zone': 'Zone001',
          'peers': <Object?>[
            <String, Object?>{'userId': 'p1', 'x': 1, 'y': 2},
          ],
        });
        expect(h.client.peers.all(), hasLength(1));
        h.socket.serverClose(code);
        expect(h.client.state, GatewayClientState.reconnecting);
        expect(h.client.peers.all(), isEmpty);
        expect(h.trace.sublist(2), [
          'disconnected:$code:true',
          'reconnecting:1:500',
        ]);
        h.elapse(499);
        expect(h.factory.sockets, hasLength(1));
        h.elapse(1);
        expect(h.factory.sockets, hasLength(2));
        h.openAndHello();
        expect(h.client.state, GatewayClientState.connected);
        expect(h.trace.last, 'connected:me');
      });
    });
  }

  test('backoff doubles to the cap and resets after a good session', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      final delays = <int>[];
      h.client.reconnecting.listen((e) => delays.add(e.delayMs));
      for (var i = 0; i < 7; i++) {
        h.socket.serverClose(4002);
        h.elapse(delays.last);
        h.socket.serverOpen();
      }
      expect(delays, [500, 1000, 2000, 4000, 8000, 15000, 15000]);
      h.socket.serverSend(helloFrame());
      h.socket.serverClose(4002);
      expect(delays.last, 500, reason: 'a successful hello resets the backoff');
    });
  });

  test('jitter is applied at both edges of the random range', () {
    fakeAsync((async) {
      var r = 0.0;
      final h = LobbyHarness(async, backoff: BackoffOptions(random: () => r))
        ..connect();
      h.openAndHello();
      final delays = <int>[];
      h.client.reconnecting.listen((e) => delays.add(e.delayMs));
      h.socket.serverClose(4002);
      h.elapse(delays.last);
      h.openAndHello();
      r = 0.999999;
      h.socket.serverClose(4002);
      expect(delays, [400, 600]);
    });
  });

  for (final (code, kind) in <(int, String)>[
    (4000, 'stop'),
    (4004, 'stop'),
    (1000, 'stop'),
    (4003, 'clientBug'),
    (1003, 'clientBug'),
    (1009, 'clientBug'),
    (4001, 'stop'),
  ]) {
    test('close $code stops without another socket', () {
      fakeAsync((async) {
        final h = LobbyHarness(async)..connect();
        h.openAndHello();
        h.socket.serverClose(code);
        h.elapse(60000);
        expect(h.factory.sockets, hasLength(1));
        expect(h.client.state, GatewayClientState.closed);
        expect(h.trace.sublist(1), [
          'disconnected:$code:false',
          'stopped:$code:$kind',
        ]);
      });
    });
  }

  test('five closes before open stop the session', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      for (var i = 0; i < 4; i++) {
        h.socket.serverError();
        expect(h.client.state, GatewayClientState.reconnecting);
        h.elapse(15000);
      }
      expect(h.factory.sockets, hasLength(5));
      h.socket.serverError();
      async.flushMicrotasks();
      expect(h.client.state, GatewayClientState.closed);
      expect(h.trace.last, 'stopped:1006:stop');
      expect(h.connectError, isA<GatewayStoppedException>());
      expect(h.factory.sockets, hasLength(5));
    });
  });

  test('a successful open resets the handshake failure count', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      for (var i = 0; i < 4; i++) {
        h.socket.serverError();
        h.elapse(15000);
      }
      h.openAndHello();
      for (var i = 0; i < 4; i++) {
        h.socket.serverError();
        h.elapse(15000);
      }
      expect(h.client.state, GatewayClientState.reconnecting);
      expect(h.factory.sockets, hasLength(9));
    });
  });

  test('maxAttempts exhaustion stops', () {
    fakeAsync((async) {
      final h = LobbyHarness(
        async,
        backoff: const BackoffOptions(maxAttempts: 2, random: _mid),
      )..connect();
      h.openAndHello();
      h.socket.serverClose(4002);
      h.elapse(500);
      h.socket.serverClose(4002);
      h.elapse(1000);
      h.socket.serverClose(4002);
      expect(h.client.state, GatewayClientState.closed);
      expect(h.trace.last, 'stopped:4002:stop');
    });
  });

  test('a new hello without partyId clears the roster', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello(hello: helloFrame(partyId: 'pty_1'));
      h.socket.serverSend(<String, Object?>{
        'type': 'party',
        'partyId': 'pty_1',
        'leaderId': 'me',
        'members': <Object?>[
          <String, Object?>{'userId': 'me', 'online': true},
        ],
      });
      expect(h.client.partyId, 'pty_1');
      expect(h.client.roster, isNotNull);
      h.socket.serverClose(4002);
      h.elapse(500);
      h.openAndHello();
      expect(h.client.partyId, isNull);
      expect(h.client.roster, isNull);
    });
  });

  test('close() during a reconnect wait cancels it', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      h.socket.serverClose(4002);
      h.client.close();
      h.elapse(60000);
      expect(h.factory.sockets, hasLength(1));
      expect(h.trace.sublist(1), [
        'disconnected:4002:true',
        'reconnecting:1:500',
      ]);
    });
  });

  test('close() from a disconnected handler suppresses the reconnect', () {
    fakeAsync((async) {
      final h = LobbyHarness(async);
      h.client.disconnected.listen((e) {
        if (e.willReconnect) h.client.close();
      });
      h.connect();
      h.openAndHello();
      h.socket.serverClose(4002);
      h.elapse(60000);
      expect(h.factory.sockets, hasLength(1));
      expect(h.trace, ['connected:me', 'disconnected:4002:true']);
      expect(h.client.state, GatewayClientState.closed);
    });
  });

  test('the whole event order of a reconnect cycle', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      h.socket.serverClose(4002, 'idle');
      h.elapse(500);
      h.openAndHello();
      h.socket.serverClose(4000);
      expect(h.trace, [
        'connected:me',
        'disconnected:4002:true',
        'reconnecting:1:500',
        'connected:me',
        'disconnected:4000:false',
        'stopped:4000:stop',
      ]);
      expect(h.states, [
        GatewayClientState.connecting,
        GatewayClientState.connected,
        GatewayClientState.reconnecting,
        GatewayClientState.connected,
        GatewayClientState.closed,
      ]);
      // The close reason is logged by length only.
      final all = h.log.lines.join('\n');
      expect(all, contains('"reasonLength":4'));
      expect(all, isNot(contains('idle')));
    });
  });
}

double _mid() => 0.5;
