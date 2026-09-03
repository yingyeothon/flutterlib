import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import 'support/harness.dart';

Map<String, Object?> peer(String id, num x, num y, [String? dir]) =>
    <String, Object?>{'userId': id, 'x': x, 'y': y, 'dir': ?dir};

void main() {
  test('snapshot, enter, leave and pos drive the peer map and the streams', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      final s = h.socket;
      s.serverSend(<String, Object?>{
        'type': 'snapshot',
        'zone': 'Z',
        'peers': <Object?>[peer('me', 0, 0), peer('a', 1, 1, 'n')],
      });
      s.serverSend(<String, Object?>{
        'type': 'enter',
        'zone': 'Z',
        ...peer('b', 2, 2),
      });
      s.serverSend(<String, Object?>{
        'type': 'enter',
        'zone': 'Z',
        ...peer('me', 9, 9),
      });
      s.serverSend(<String, Object?>{
        'type': 'enter',
        'zone': 'Other',
        ...peer('c', 3, 3),
      });
      s.serverSend(<String, Object?>{
        'type': 'pos',
        'zone': 'Z',
        'peers': <Object?>[
          peer('me', 5, 5),
          peer('a', 1.5, 1.5),
          peer('ghost', 0, 0),
        ],
      });
      s.serverSend(<String, Object?>{
        'type': 'pos',
        'zone': 'Other',
        'peers': <Object?>[peer('a', 7, 7)],
      });
      s.serverSend(<String, Object?>{
        'type': 'leave',
        'zone': 'Z',
        'userId': 'b',
      });
      s.serverSend(<String, Object?>{
        'type': 'leave',
        'zone': 'Z',
        'userId': 'nobody',
      });
      expect(h.trace, [
        'connected:me',
        'snapshot:Z',
        'enter:b',
        'move:a',
        'leave:b',
      ]);
      expect(h.client.peers.zone, 'Z');
      expect(h.client.peers.all().map((p) => p.userId), ['a']);
      final a = h.client.peers.get('a')!;
      expect((a.x, a.y), (1.5, 1.5));
      expect(a.dir, isNull, reason: 'an omitted dir clears the facing');
      expect(h.client.peers.get('me'), isNull);
    });
  });

  test('a snapshot replaces the map and keeps insertion order', () {
    final map = PeerMap(selfUserId: 'me');
    map.apply(
      readLobbyFrame(<String, Object?>{
        'type': 'snapshot',
        'zone': 'Z',
        'peers': <Object?>[peer('b', 0, 0), peer('a', 0, 0)],
      }),
    );
    map.apply(
      readLobbyFrame(<String, Object?>{
        'type': 'enter',
        'zone': 'Z',
        ...peer('c', 0, 0),
      }),
    );
    expect(map.all().map((p) => p.userId), ['b', 'a', 'c']);
    final change = map.apply(
      readLobbyFrame(<String, Object?>{
        'type': 'snapshot',
        'zone': 'Y',
        'peers': <Object?>[peer('d', 1, 1)],
      }),
    );
    expect(change, isA<PeerSnapshot>());
    expect((change! as PeerSnapshot).zone, 'Y');
    expect(map.all().map((p) => p.userId), ['d']);
    map.reset();
    expect(map.zone, isNull);
    expect(map.all(), isEmpty);
    expect(
      map.apply(
        readLobbyFrame(<String, Object?>{
          'type': 'enter',
          'zone': 'Y',
          ...peer('e', 0, 0),
        }),
      ),
      isNull,
      reason: 'no zone until a snapshot',
    );
  });

  test('party frames are normalised for omitempty', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      PartyFrame? seen;
      h.client.partyChanged.listen((f) => seen = f);
      h.socket.serverSend(<String, Object?>{'type': 'party', 'partyId': ''});
      expect(seen!.partyId, isNull);
      expect(seen!.leaderId, '');
      expect(seen!.members, isEmpty);
      expect(seen!.invited, isEmpty);
      expect(seen!.max, 0);
      expect(h.client.partyId, isNull);
      h.socket.serverSend(<String, Object?>{
        'type': 'party',
        'partyId': 'pty_1',
        'leaderId': 'me',
        'members': <Object?>[
          <String, Object?>{'userId': 'me', 'online': true},
          <String, Object?>{'userId': 'b', 'online': false},
        ],
        'invited': <Object?>['c'],
        'max': 4,
      });
      expect(h.client.partyId, 'pty_1');
      expect(seen!.members, [
        const PartyMember(userId: 'me', online: true),
        const PartyMember(userId: 'b', online: false),
      ]);
      expect(seen!.invited, ['c']);
      expect(seen!.max, 4);
      expect(h.client.roster, same(seen));
    });
  });

  test('say, event, invites, declined, pong, error and unknown route', () {
    fakeAsync((async) {
      final h = LobbyHarness(async)..connect();
      h.openAndHello();
      final frames = <String>[];
      h.client.frames.listen((f) => frames.add(f.type));
      SayBroadcastFrame? say;
      final events = <EventBroadcastFrame>[];
      h.client.said.listen((f) => say = f);
      h.client.eventReceived.listen(events.add);
      final s = h.socket;
      s.serverSend(<String, Object?>{
        'type': 'say',
        'from': 'a',
        'scope': 'user',
        'to': 'me',
        'text': 'hi',
      });
      s.serverSend(<String, Object?>{
        'type': 'event',
        'from': 'a',
        'scope': 'zone',
        'name': 'cast',
        'payload': <Object?>[1],
      });
      s.serverSend(<String, Object?>{
        'type': 'event',
        'from': 'a',
        'scope': 'weird',
        'name': 'x',
      });
      s.serverSend(<String, Object?>{
        'type': 'party.invite',
        'partyId': 'p',
        'from': 'a',
      });
      s.serverSend(<String, Object?>{
        'type': 'party.declined',
        'partyId': 'p',
        'userId': 'b',
      });
      s.serverSend(<String, Object?>{'type': 'pong'});
      s.serverSend(<String, Object?>{
        'type': 'error',
        'code': 'bad_zone',
        'message': 'zone x',
      });
      s.serverSend(<String, Object?>{'type': 'future.thing'});
      expect(h.trace, [
        'connected:me',
        'say:a:hi',
        'event:a:cast',
        'event:a:x',
        'invite:p',
        'declined:b',
        'pong',
        'refused:bad_zone',
        'protocolError:unknown frame type future.thing',
      ]);
      expect(frames, [
        'say',
        'event',
        'event',
        'party.invite',
        'party.declined',
        'pong',
        'error',
        'future.thing',
      ]);
      expect(say!.to, 'me');
      expect(say!.sayScope, SayScope.user);
      expect(events[0].payload, <Object?>[1]);
      expect(events[0].to, isNull);
      expect(events[1].payload, isNull);
      expect(events[1].sayScope, isNull);
      final logs = h.log.lines.join('\n');
      expect(logs, contains('"code":"bad_zone"'));
      expect(
        logs,
        isNot(contains('zone x')),
        reason: 'the message is not logged',
      );
    });
  });

  test('to absent and to empty both read as null', () {
    final a = readLobbyFrame(<String, Object?>{
      'type': 'say',
      'scope': 'zone',
      'text': '',
    }) as SayBroadcastFrame;
    final b = readLobbyFrame(<String, Object?>{
      'type': 'say',
      'scope': 'zone',
      'text': '',
      'to': '',
    }) as SayBroadcastFrame;
    expect(a.to, isNull);
    expect(b.to, isNull);
  });

  test('hello fields and aoi range', () {
    final hello = Hello.fromJson(
      helloFrame(
        partyId: 'pty_9',
        aoi: <String, Object?>{'range': 10, 'maxPeers': 8},
      ),
    );
    expect(hello.partyId, 'pty_9');
    expect(hello.aoi!.range, 10.0);
    expect(hello.aoi!.maxPeers, 8);
    expect(hello.capabilities.say, ['zone', 'party', 'user']);
    expect(hello.capabilities.debug, isFalse);
    expect(hello.raw['connectionId'], 'c1');
    final bare = Hello.fromJson(<String, Object?>{
      'type': 'hello',
      'partyId': '',
    });
    expect(bare.partyId, isNull);
    expect(bare.aoi, isNull);
    expect(bare.capabilities.pos, isNull);
  });
}
