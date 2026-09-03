import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

void main() {
  group('classifyClose', () {
    test('covers every documented code for both kinds', () {
      CloseDispositionKind k(int code, GatewayChannelKind kind) =>
          classifyClose(code, kind).kind;
      const lobby = GatewayChannelKind.lobby;
      const q = GatewayChannelKind.q;
      expect(k(4000, lobby), CloseDispositionKind.stop);
      expect(k(4001, lobby), CloseDispositionKind.stop);
      expect(k(4001, q), CloseDispositionKind.aborted);
      expect(k(4002, lobby), CloseDispositionKind.reconnect);
      expect(k(4003, lobby), CloseDispositionKind.clientBug);
      expect(k(4004, q), CloseDispositionKind.stop);
      expect(k(4005, lobby), CloseDispositionKind.reconnect);
      expect(k(1000, lobby), CloseDispositionKind.stop);
      expect(k(1000, q), CloseDispositionKind.finished);
      expect(k(1001, q), CloseDispositionKind.reconnect);
      expect(k(1003, lobby), CloseDispositionKind.clientBug);
      expect(k(1009, lobby), CloseDispositionKind.clientBug);
      expect(k(1011, q), CloseDispositionKind.reconnect);
      expect(k(1006, lobby), CloseDispositionKind.reconnect);
      expect(classifyClose(4242, lobby).reason, 'connection lost (4242)');
    });
  });

  group('buildGatewayUrl', () {
    test('adds channel and gameId, escapes, keeps other query', () {
      expect(
        buildGatewayUrl('wss://gw.example', 'ch').toString(),
        'wss://gw.example?channel=ch',
      );
      expect(
        buildGatewayUrl('wss://gw.example/', 'ch', 'g 1').toString(),
        'wss://gw.example/?channel=ch&gameId=g+1',
      );
      expect(
        buildGatewayUrl('wss://gw.example/?x=1&channel=old', 'new').toString(),
        'wss://gw.example/?x=1&channel=new',
      );
      expect(
        buildGatewayUrl('wss://gw.example/?gameId=old', 'c').toString(),
        'wss://gw.example/?channel=c',
      );
      expect(
        buildGatewayUrl('ws://h', '한').toString(),
        'ws://h?channel=%ED%95%9C',
      );
    });
  });

  group('Backoff', () {
    test('sequence, cap, jitter edges and reset', () {
      var r = 0.5;
      final b = Backoff(BackoffOptions(random: () => r));
      expect([b.next(), b.next(), b.next()], [500, 1000, 2000]);
      expect(b.attempts, 3);
      for (var i = 0; i < 4; i++) {
        b.next();
      }
      expect(b.next(), 15000);
      b.reset();
      r = 0;
      expect(b.next(), 400);
      r = 0.999999;
      expect(b.next(), 1200);
    });

    test('maxAttempts', () {
      final b = Backoff(const BackoffOptions(maxAttempts: 1, jitter: 0));
      expect(b.next(), 500);
      expect(b.next(), isNull);
      b.reset();
      expect(b.next(), 500);
    });

    test('two default backoffs do not share a random source', () {
      final seen = <int>{};
      for (var i = 0; i < 20; i++) {
        seen.add(Backoff().next()!);
      }
      expect(seen.length, greaterThan(1));
      expect(seen.every((d) => d >= 400 && d <= 600), isTrue);
    });
  });

  group('Normalize', () {
    test('diagnostic caps at 32 and replaces control characters', () {
      expect(Normalize.diagnostic('x' * 32), 'x' * 32);
      expect(Normalize.diagnostic('x' * 33), '${'x' * 32}…');
      expect(Normalize.diagnostic('a\nb\x7fc\tд'), 'a?b?c?д');
      expect(Normalize.diagnostic(''), '');
    });

    test('optionalId', () {
      expect(Normalize.optionalId(null), isNull);
      expect(Normalize.optionalId(''), isNull);
      expect(Normalize.optionalId('x'), 'x');
    });
  });

  group('frame writer', () {
    test('event without payload omits the field; null to is omitted', () {
      expect(LobbyFrameWriter.event(SayScope.zone, 'n', null, null), {
        'type': 'event',
        'scope': 'zone',
        'name': 'n',
      });
      expect(isDirTooLong('a' * 16), isFalse);
      expect(isDirTooLong('a' * 17), isTrue);
    });
  });

  group('SayScope', () {
    test('parses only the three scopes', () {
      expect(SayScope.tryParse('zone'), SayScope.zone);
      expect(SayScope.tryParse('party'), SayScope.party);
      expect(SayScope.tryParse('user'), SayScope.user);
      expect(SayScope.tryParse('other'), isNull);
      expect(SayScope.tryParse(null), isNull);
    });
  });

  group('Peer', () {
    test('equality and fromJson', () {
      expect(
        Peer.fromJson(<String, Object?>{
          'userId': 'a',
          'x': 1,
          'y': 2,
          'dir': 'n',
        }),
        const Peer(userId: 'a', x: 1, y: 2, dir: 'n'),
      );
      expect(Peer.fromJson(<String, Object?>{'x': 1}), isNull);
      expect(Peer.fromJson('nope'), isNull);
      expect(
        const Peer(userId: 'a', x: 1, y: 2).toString(),
        'Peer(a, 1.0, 2.0, null)',
      );
    });
  });
}
