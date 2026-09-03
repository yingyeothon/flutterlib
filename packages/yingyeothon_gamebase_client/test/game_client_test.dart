import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import 'support/harness.dart';

void main() {
  test('opens with channel and gameId, is ready on open', () {
    fakeAsync((async) {
      final h = GameHarness(async)..connect();
      expect(
        h.socket.request.url.toString(),
        '$fixtureGatewayUrl?channel=q_0123456789abcdef&gameId=g_0123456789abcdef',
      );
      expect(h.socket.request.subprotocols, ['bearer', fixtureToken]);
      h.socket.serverOpen();
      async.flushMicrotasks();
      expect(h.client.state, GatewayClientState.connected);
      expect(h.trace, ['connected']);
      expect(h.connectError, isNull);
    });
  });

  test('the first frame can be sent from the connected handler', () {
    fakeAsync((async) {
      final h = GameHarness(async);
      h.client.connected.listen(
        (_) => h.client.send(<String, Object?>{'type': 'ready'}),
      );
      h.connect();
      h.socket.serverOpen();
      expect(h.socket.sentRaw, ['{"type":"ready"}']);
    });
  });

  test('frames pass through verbatim, including non-objects', () {
    fakeAsync((async) {
      final h = GameHarness(async)..connect();
      h.socket.serverOpen();
      h.socket.serverSendRaw('{"type":"state","hp":3}');
      h.socket.serverSendRaw('[1,2]');
      h.socket.serverSendRaw('7');
      h.socket.serverSendRaw('"text"');
      h.socket.serverSendRaw('{"type":"error"}');
      h.socket.serverSendRaw('{"type":"error","code":"unavailable"}');
      h.socket.serverSendRaw('{not json');
      expect(h.trace, [
        'connected',
        'frame:{"type":"state","hp":3}',
        'frame:[1,2]',
        'frame:7',
        'frame:"text"',
        'frame:{"type":"error"}',
        'refused:unavailable',
        'protocolError:frame is not JSON: malformed at 1',
      ]);
    });
  });

  test('enter and leave are refused locally', () {
    fakeAsync((async) {
      final h = GameHarness(async)..connect();
      h.socket.serverOpen();
      for (final type in reservedGameFrameTypes) {
        expect(
          () => h.client.send(<String, Object?>{'type': type}),
          throwsStateError,
        );
      }
      h.client.send(<String, Object?>{'type': 'move', 'dx': 1});
      h.client.send(<String, Object?>{'noType': true});
      expect(h.socket.sent, hasLength(2));
    });
  });

  test('4001 is aborted, 1000 is finished, neither reconnects', () {
    for (final (code, name) in <(int, String)>[
      (4001, 'aborted'),
      (1000, 'finished'),
    ]) {
      fakeAsync((async) {
        final h = GameHarness(async)..connect();
        h.socket.serverOpen();
        h.socket.serverClose(code);
        h.elapse(60000);
        expect(h.trace, [
          'connected',
          'disconnected:$code:false',
          '$name:$code',
        ]);
        expect(h.factory.sockets, hasLength(1));
        expect(h.client.state, GatewayClientState.closed);
      });
    }
  });

  test('4002 reconnects and the client is usable again', () {
    fakeAsync((async) {
      final h = GameHarness(async)..connect();
      h.socket.serverOpen();
      h.socket.serverClose(4002);
      expect(
        () => h.client.send(<String, Object?>{'type': 'x'}),
        throwsStateError,
      );
      h.elapse(500);
      h.socket.serverOpen();
      h.client.send(<String, Object?>{'type': 'x'});
      expect(h.trace, [
        'connected',
        'disconnected:4002:true',
        'reconnecting:1:500',
        'connected',
      ]);
    });
  });

  test('4000 and 4004 are stopped, not aborted or finished', () {
    for (final code in <int>[4000, 4004]) {
      fakeAsync((async) {
        final h = GameHarness(async)..connect();
        h.socket.serverOpen();
        h.socket.serverClose(code);
        expect(h.trace.last, 'stopped:$code:stop');
      });
    }
  });

  test('a refused handshake fails connect and never logs the token', () {
    fakeAsync((async) {
      final h = GameHarness(async, maxHandshakeFailures: 1)..connect();
      h.socket.serverError();
      async.flushMicrotasks();
      expect(h.connectError, isA<GatewayStoppedException>());
      final all = h.log.lines.join('\n');
      expect(all, contains('gateway connection stopped'));
      expect(all, isNot(contains(fixtureToken)));
    });
  });

  test('a refusal is logged by code, not message', () {
    fakeAsync((async) {
      final h = GameHarness(async)..connect();
      h.socket.serverOpen();
      h.socket.serverSendRaw(
        '{"type":"error","code":"rate_limited","message":"eyJ.secret-token.sig"}',
      );
      final all = h.log.lines.join('\n');
      expect(all, contains('rate_limited'));
      expect(all, isNot(contains('secret-token')));
    });
  });

  test('close() releases the client', () {
    fakeAsync((async) {
      final h = GameHarness(async)..connect();
      h.socket.serverOpen();
      h.client.close();
      h.client.close();
      async.flushMicrotasks();
      expect(h.socket.clientCloseCode, 1000);
      expect(h.trace, ['connected', 'disconnected:1000:false']);
    });
  });
}
