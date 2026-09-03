import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import 'support/harness.dart';

void main() {
  test('every sender pins its wire bytes', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      h.client
        ..pos(zone: 'z', x: 1, y: 2)
        ..pos(zone: 'z', x: 1.5, y: -2, dir: 'n')
        ..say(scope: SayScope.zone, text: 'hi')
        ..say(scope: SayScope.user, text: 'psst', to: 'u2')
        ..event(
          scope: SayScope.party,
          name: 'cast',
          payload: <String, Object?>{'id': 3},
        )
        ..event(scope: SayScope.zone, name: 'ping')
        ..ping();
      h.client.party
        ..create()
        ..invite('u2')
        ..accept('pty_1')
        ..decline('pty_2')
        ..leave()
        ..list();
      h.client.send(<String, Object?>{'type': 'custom', 'k': 'v'});
      expect(h.socket.sentRaw, [
        '{"type":"pos","zone":"z","x":1.0,"y":2.0}',
        '{"type":"pos","zone":"z","x":1.5,"y":-2.0,"dir":"n"}',
        '{"type":"say","scope":"zone","text":"hi"}',
        '{"type":"say","scope":"user","to":"u2","text":"psst"}',
        '{"type":"event","scope":"party","name":"cast","payload":{"id":3}}',
        '{"type":"event","scope":"zone","name":"ping"}',
        '{"type":"ping"}',
        '{"type":"party.create"}',
        '{"type":"party.invite","userId":"u2"}',
        '{"type":"party.accept","partyId":"pty_1"}',
        '{"type":"party.decline","partyId":"pty_2"}',
        '{"type":"party.leave"}',
        '{"type":"party.list"}',
        '{"type":"custom","k":"v"}',
      ]);
    });
  });

  test('only an explicit false capability refuses locally', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello(
        hello: helloFrame(
          capabilities: <String, Object?>{
            'pos': false,
            'party': false,
            'event': false,
            'say': <Object?>['party'],
          },
        ),
      );
      expect(() => h.client.pos(zone: 'z', x: 0, y: 0), throwsStateError);
      expect(() => h.client.party.create(), throwsStateError);
      expect(() => h.client.party.invite('u'), throwsStateError);
      expect(() => h.client.party.accept('p'), throwsStateError);
      expect(() => h.client.party.decline('p'), throwsStateError);
      expect(() => h.client.party.leave(), throwsStateError);
      expect(() => h.client.party.list(), throwsStateError);
      expect(
        () => h.client.event(scope: SayScope.party, name: 'n'),
        throwsStateError,
      );
      expect(
        () => h.client.say(scope: SayScope.zone, text: 't'),
        throwsStateError,
      );
      h.client.say(scope: SayScope.party, text: 'ok');
      h.client.ping();
      expect(h.socket.sent, hasLength(2));
    });
  });

  test('an empty capabilities object allows everything', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello(hello: helloFrame(capabilities: <String, Object?>{}));
      h.client
        ..pos(zone: 'z', x: 0, y: 0)
        ..say(scope: SayScope.user, text: 't', to: 'u')
        ..event(scope: SayScope.zone, name: 'n');
      h.client.party.create();
      expect(h.socket.sent, hasLength(4));
    });
  });

  test('say null is unrestricted, say [] refuses every scope', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello(
        hello: helloFrame(capabilities: <String, Object?>{'say': null}),
      );
      h.client.say(scope: SayScope.zone, text: 't');
      h.socket.serverClose(4002);
      h.elapse(500);
      h.openAndHello(
        hello: helloFrame(capabilities: <String, Object?>{'say': <Object?>[]}),
      );
      for (final scope in SayScope.values) {
        expect(() => h.client.say(scope: scope, text: 't'), throwsStateError);
      }
    });
  });

  test('event is gated by the event flag and the say scopes', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello(
        hello: helloFrame(
          capabilities: <String, Object?>{
            'event': true,
            'say': <Object?>['zone'],
          },
        ),
      );
      h.client.event(scope: SayScope.zone, name: 'n');
      expect(
        () => h.client.event(scope: SayScope.party, name: 'n'),
        throwsStateError,
      );
    });
  });

  test('dir is measured in bytes: 16 passes, 17 is refused', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      h.client.pos(zone: 'z', x: 0, y: 0, dir: 'a' * 16);
      h.client.pos(zone: 'z', x: 0, y: 0, dir: '한' * 5); // 15 bytes
      expect(
        () => h.client.pos(zone: 'z', x: 0, y: 0, dir: 'a' * 17),
        throwsArgumentError,
      );
      expect(
        () => h.client.pos(zone: 'z', x: 0, y: 0, dir: '한' * 6),
        throwsArgumentError,
      );
      expect(h.socket.sent, hasLength(2));
    });
  });

  test('sending outside connected is refused', () {
    fakeAsync((async) {
      final h = LobbyHarness(async);
      expect(() => h.client.ping(), throwsStateError);
      h.connect();
      h.socket.serverOpen();
      expect(() => h.client.ping(), throwsStateError);
      h.socket.serverSend(helloFrame());
      h.client.ping();
      h.socket.serverClose(4002);
      expect(() => h.client.ping(), throwsStateError);
      expect(h.socket.sent, hasLength(1));
    });
  });
}
