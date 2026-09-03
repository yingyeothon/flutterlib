import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import 'support/harness.dart';

void main() {
  test('opens the channel URL with the bearer subprotocol list', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      final request = h.socket.request;
      expect(
        request.url.toString(),
        '$fixtureGatewayUrl?channel=$fixtureChannelId',
      );
      expect(request.subprotocols, <String>['bearer', fixtureToken]);
      expect(h.client.state, GatewayClientState.connecting);
    });
  });

  test('open alone is not connected; hello is', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.socket.serverOpen();
      async.flushMicrotasks();
      expect(h.client.state, GatewayClientState.connecting);
      expect(h.client.hello, isNull);
      expect(h.trace, isEmpty);
      h.socket.serverSend(helloFrame(zone: 'Z'));
      async.flushMicrotasks();
      expect(h.client.state, GatewayClientState.connected);
      expect(h.client.hello!.zone, 'Z');
      expect(h.client.hello!.aoi!.maxPeers, 64);
      expect(h.client.hello!.aoi!.range, isNull);
      expect(h.trace, ['connected:me']);
      expect(h.states, [
        GatewayClientState.connecting,
        GatewayClientState.connected,
      ]);
    });
  });

  test('connect() completes after hello was delivered to listeners', () {
    fakeAsync((async) {
      final h = LobbyHarness(async);
      var sawHelloBeforeCompletion = false;
      h.client.connected.listen((_) {
        sawHelloBeforeCompletion = h.client.hello != null;
      });
      h.connect();
      Hello? result;
      h.connectFuture.then((hello) => result = hello);
      h.openAndHello();
      expect(sawHelloBeforeCompletion, isTrue);
      expect(result, isNotNull);
      expect(result!.userId, 'me');
    });
  });

  test(
    'a non-hello first frame is a protocol error and the wait continues',
    () {
      fakeAsync((async) {
        final h = LobbyHarness(async)..connect();
        h.socket.serverOpen();
        h.socket.serverSend(<String, Object?>{'type': 'snapshot', 'zone': 'z'});
        expect(h.trace, ['protocolError:expected hello, got snapshot']);
        expect(h.client.state, GatewayClientState.connecting);
        h.socket.serverSend(helloFrame());
        expect(h.trace.last, 'connected:me');
      });
    },
  );

  test('a peer-chosen type in a diagnostic is capped and cleaned', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.socket.serverOpen();
      final long = 'x' * 40;
      h.socket.serverSend(<String, Object?>{'type': long});
      h.socket.serverSend(<String, Object?>{'type': 'a\nbc'});
      expect(h.trace, [
        'protocolError:expected hello, got ${'x' * 32}…',
        'protocolError:expected hello, got a?b?c',
      ]);
    });
  });

  test('frames that are not the protocol are reported, never delivered', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.socket.serverOpen();
      h.socket.serverSendRaw('{not json');
      h.socket.serverSendRaw('[1,2]');
      h.socket.serverSendRaw('{"type":5}');
      h.socket.serverSendBinary();
      expect(h.trace, [
        'protocolError:frame is not JSON: malformed at 1',
        'protocolError:frame is not an object',
        'protocolError:frame has no string type',
        'protocolError:non-text frame',
      ]);
      expect(h.client.state, GatewayClientState.connecting);
    });
  });

  test('hello timeout closes that socket and reconnects; 9999 ms does not', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      final first = h.socket;
      first.serverOpen();
      h.elapse(9999);
      expect(first.clientCloseCode, isNull);
      h.elapse(1);
      expect(first.clientCloseCode, GatewayCloseCode.local);
      expect(h.client.state, GatewayClientState.reconnecting);
      expect(h.trace, ['disconnected:4900:true', 'reconnecting:1:500']);
      expect(h.connectError, isNull, reason: 'connect keeps waiting');
      h.elapse(500);
      expect(h.factory.sockets, hasLength(2));
      h.openAndHello();
      expect(h.trace.last, 'connected:me');
      expect(h.client.state, GatewayClientState.connected);
    });
  });

  test('hello cancels the timer', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      h.elapse(20000);
      expect(h.socket.clientCloseCode, isNull);
      expect(h.client.state, GatewayClientState.connected);
    });
  });

  test('a gateway that does not echo bearer stops the session', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.socket.serverOpen(null);
      async.flushMicrotasks();
      expect(h.socket.clientCloseCode, GatewayCloseCode.local);
      expect(h.client.state, GatewayClientState.closed);
      expect(h.trace, ['disconnected:4900:false', 'stopped:4900:stop']);
      expect(h.connectError, isA<GatewayStoppedException>());
      expect(h.factory.sockets, hasLength(1));
    });
  });

  test('a hello queued behind a subprotocol refusal does not connect', () {
    fakeAsync((async) {
      final h = LobbyHarness(async);
      h.factory.deferClose = true;
      h.connect();
      h.socket.serverOpen('other');
      // The transport has not reported the close yet; a queued hello arrives.
      h.socket.serverSend(helloFrame());
      expect(h.client.state, GatewayClientState.connecting);
      expect(h.client.hello, isNull);
      h.socket.flushClose();
      expect(h.client.state, GatewayClientState.closed);
      expect(h.trace, ['disconnected:4900:false', 'stopped:4900:stop']);
    });
  });

  test('a hello arriving after the hello timeout is ignored', () {
    fakeAsync((async) {
      final h = LobbyHarness(async);
      h.factory.deferClose = true;
      h.connect();
      h.socket.serverOpen();
      h.elapse(10000);
      h.socket.serverSend(helloFrame());
      expect(h.client.hello, isNull);
      h.socket.flushClose();
      expect(h.client.state, GatewayClientState.reconnecting);
    });
  });

  test('a factory that throws stops the session without quoting the error', () {
    fakeAsync((async) {
      final h = LobbyHarness(async);
      h.factory.createOverride = (_) =>
          throw ArgumentError('bad url $fixtureToken');
      h.connect();
      expect(h.client.state, GatewayClientState.closed);
      expect(h.trace, ['disconnected:0:false', 'stopped:0:stop']);
      expect(h.connectError, isA<GatewayStoppedException>());
      expect(h.log.lines.join('\n'), isNot(contains(fixtureToken)));
    });
  });

  test('connect() twice is refused', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      expect(() => h.client.connect(), throwsStateError);
    });
  });

  test('the token never reaches a log line, with a positive control', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      h.socket.serverClose(4002);
      h.elapse(500);
      h.socket.serverClose(4000);
      final all = h.log.lines.join('\n');
      expect(all, contains('lobby connected'), reason: 'positive control');
      expect(all, contains('gateway reconnecting'));
      expect(all, contains('gateway connection stopped'));
      expect(all, isNot(contains(fixtureToken)));
      expect(all, isNot(contains('secret-token')));
      expect(all, isNot(contains('bearer')));
    });
  });

  test('a handler can send from inside connected', () {
    fakeAsync((async) {
      final h = LobbyHarness(async);
      h.client.connected.listen(
        (hello) => h.client.pos(zone: hello.zone, x: 1, y: 2, dir: 'n'),
      );
      h.connect();
      h.openAndHello();
      expect(h.socket.sentRaw, [
        '{"type":"pos","zone":"Zone001","x":1.0,"y":2.0,"dir":"n"}',
      ]);
    });
  });

  test('a frame sent from inside a frame handler keeps order', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      var nested = false;
      h.client.said.listen((f) {
        if (nested) return;
        nested = true;
        h.socket.serverSend(<String, Object?>{
          'type': 'say',
          'from': 'b',
          'scope': 'zone',
          'text': 'nested',
        });
        h.trace.add('after-nested-send');
      });
      h.socket.serverSend(<String, Object?>{
        'type': 'say',
        'from': 'a',
        'scope': 'zone',
        'text': 'outer',
      });
      expect(h.trace, [
        'connected:me',
        'say:a:outer',
        'after-nested-send',
        'say:b:nested',
      ]);
    });
  });

  test('close() before hello fails connect and ignores a late open', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      final first = h.socket;
      h.client.close();
      async.flushMicrotasks();
      expect(h.connectError, isA<GatewayStoppedException>());
      expect(first.clientCloseCode, 1000);
      expect(h.client.state, GatewayClientState.closed);
      expect(h.trace, ['disconnected:1000:false']);
    });
  });

  test('close() is idempotent and releases the streams', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      h.client.close();
      h.client.close();
      async.flushMicrotasks();
      expect(h.trace, ['connected:me', 'disconnected:1000:false']);
      expect(() => h.client.pos(zone: 'z', x: 0, y: 0), throwsStateError);
    });
  });

  test('a socket from an earlier attempt is ignored', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      final first = h.socket;
      first.serverOpen();
      h.elapse(10000); // hello timeout retires it
      h.elapse(500);
      final second = h.socket;
      expect(second, isNot(same(first)));
      second.serverOpen();
      second.serverSend(helloFrame(userId: 'second'));
      expect(h.client.hello!.userId, 'second');
      // A FakeWebSocket that was closed refuses more events, which is the
      // transport contract; the state machine ignores by identity anyway.
      expect(first.isClosed, isTrue);
    });
  });
}
