// Drives the fake's `/social/*` routes with a raw HttpClient, so the fake is
// tested against the protocol (`services/state/src/social.ts` and the
// planners in `packages/console-db/src/social.ts`), not against the client
// library it exists to test.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

final class Answer {
  Answer(this.status, this.body);
  final int status;
  final String body;
  Map<String, Object?> get json => jsonDecode(body) as Map<String, Object?>;
  String? get reason =>
      ((json['error'] as Map<String, Object?>?)?['details']
              as Map<String, Object?>?)?['reason']
          as String?;
}

const String server = 'yds.auth_0123456789abcdef.k';

Future<Answer> call(
  Uri base,
  String method,
  String path, {
  String? token = 'alice',
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, base.resolve(path));
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    return Answer(response.statusCode, await utf8.decodeStream(response));
  } finally {
    client.close();
  }
}

void main() {
  late FakeGateway gw;
  var now = DateTime.utc(2026, 10, 1, 0, 0);

  setUp(() async {
    now = DateTime.utc(2026, 10, 1, 0, 0);
    gw = await FakeGateway.start(
      options: FakeGatewayOptions(
        clock: () => now,
        socialProfiles: const <FakeSocialProfile>[
          FakeSocialProfile(
            owner: 'bob',
            displayName: 'Bob',
            avatar: 'heroes/knight',
          ),
          FakeSocialProfile(owner: 'carol', displayName: 'Carol'),
        ],
      ),
    );
  });

  tearDown(() => gw.shutdown());

  Future<Answer> me(String method, String path, {String? body}) =>
      call(gw.kvUrl, method, path, body: body);
  Future<Answer> as(String who, String method, String path, {String? body}) =>
      call(gw.kvUrl, method, path, token: who, body: body);

  test('a card is required, whole on PUT, and checked as the service checks', () async {
    expect((await me('GET', '/social/me/profile')).status, 404);
    var r = await me(
      'PUT',
      '/social/me/profile',
      body: '{"displayName":"  Alice  ","avatar":"heroes/mage"}',
    );
    expect(r.status, 201);
    expect(r.json['owner'], 'alice');
    expect(r.json['displayName'], 'Alice', reason: 'trimmed');
    expect(r.json['avatar'], 'heroes/mage');
    final first = r.json['updatedAt'];
    now = now.add(const Duration(minutes: 1));
    r = await me(
      'PUT',
      '/social/me/profile',
      body: '{"displayName":"Alice","avatar":"heroes/mage"}',
    );
    expect(r.status, 200);
    expect(
      r.json['updatedAt'],
      first,
      reason: 'an identical PUT leaves updatedAt',
    );
    r = await me('PUT', '/social/me/profile', body: '{"displayName":"Alice"}');
    expect(r.json['avatar'], isNull, reason: 'absent clears');
    expect(r.json['updatedAt'], isNot(first));
    for (final bad in <String>[
      '{"displayName":""}',
      '{"displayName":"${'x' * 33}"}',
      '{"displayName":"a\\u0000b"}',
      '{"displayName":"a\\u200db"}',
      '{"displayName":"a\\u2028b"}',
      '{"displayName":"e${'\\u0301' * 5}"}',
      '{"displayName":"ok","avatar":"https://x/y"}',
      '{"displayName":"ok","avatar":"/abs"}',
      '{"displayName":"ok","avatar":"${'a' * 65}"}',
      '{"displayName":5}',
      '{}',
    ]) {
      expect(
        (await me('PUT', '/social/me/profile', body: bad)).status,
        400,
        reason: bad,
      );
    }
    expect(
      (await me(
        'PUT',
        '/social/me/profile',
        body: '{"displayName":"${'x' * 32}"}',
      )).status,
      200,
    );
    // A server key is named the owner in the path, never `me`.
    expect((await as(server, 'GET', '/social/me/profile')).status, 403);
    expect(
      (await as(
        server,
        'PUT',
        '/social/u/guild:red/profile',
        body: '{"displayName":"Red"}',
      )).status,
      201,
    );
    expect(
      (await as(
        'bob',
        'PUT',
        '/social/u/bob/profile',
        body: '{"displayName":"B"}',
      )).status,
      403,
    );
    final many = await me(
      'GET',
      '/social/profiles?ids=alice,bob,nobody,guild:red,bob',
    );
    expect(many.status, 200);
    expect(
      (many.json['profiles'] as List<Object?>).map((p) => (p! as Map)['owner']),
      ['alice', 'bob', 'guild:red'],
    );
    expect(
      (await me(
        'GET',
        '/social/profiles?ids=${List.filled(51, 'x').asMap().entries.map((e) => 'p${e.key}').join(',')}',
      )).status,
      400,
    );
    expect(
      (await call(gw.kvUrl, 'GET', '/social/friends', token: null)).status,
      401,
    );
  });

  test('request, accept, decline, withdraw, unfriend', () async {
    // No card: profile_required for me; a target without a card is a 404.
    var r = await me('POST', '/social/requests', body: '{"to":"bob"}');
    expect(r.status, 409);
    expect(r.reason, 'profile_required');
    await me('PUT', '/social/me/profile', body: '{"displayName":"Alice"}');
    expect(
      (await me('POST', '/social/requests', body: '{"to":"nobody"}')).reason,
      'not_found',
    );
    expect(
      (await me('POST', '/social/requests', body: '{"to":"alice"}')).status,
      400,
    );
    r = await me('POST', '/social/requests', body: '{"to":"bob"}');
    expect(r.status, 201);
    expect(r.json['state'], 'requested');
    r = await me('POST', '/social/requests', body: '{"to":"bob"}');
    expect(r.status, 200, reason: 'a re-request writes nothing');
    expect(gw.social.relation('alice', 'bob'), 'requested');
    final inbox = await as('bob', 'GET', '/social/requests');
    expect(
      ((inbox.json['incoming'] as List<Object?>).single! as Map)['owner'],
      'alice',
    );
    expect(
      ((inbox.json['incoming'] as List<Object?>).single! as Map)['displayName'],
      'Alice',
    );
    expect(inbox.json['outgoing'], isEmpty);
    // Accept: friends both ways, with cards folded in.
    expect(
      (await as('bob', 'POST', '/social/requests/alice/accept')).status,
      204,
    );
    expect(
      (await as('bob', 'POST', '/social/requests/alice/accept')).status,
      404,
    );
    expect(gw.social.relation('alice', 'bob'), 'friends');
    expect(gw.social.relation('bob', 'alice'), 'friends');
    final friends = await me('GET', '/social/friends');
    final row = (friends.json['friends'] as List<Object?>).single! as Map;
    expect(row['owner'], 'bob');
    expect(row['avatar'], 'heroes/knight');
    expect(row['since'], isA<int>());
    // A request between friends heals rather than asks.
    r = await me('POST', '/social/requests', body: '{"to":"bob"}');
    expect(r.json['state'], 'friends');
    // Decline keeps the row as a cooldown the sender still sees as pending.
    expect(
      (await me('POST', '/social/requests', body: '{"to":"carol"}')).status,
      201,
    );
    expect(
      (await as('carol', 'POST', '/social/requests/alice/decline')).status,
      204,
    );
    expect(gw.social.relation('alice', 'carol'), 'dropped');
    final outbox = await me('GET', '/social/requests');
    expect(
      ((outbox.json['outgoing'] as List<Object?>).single! as Map)['owner'],
      'carol',
    );
    expect(
      (await as('carol', 'GET', '/social/requests')).json['incoming'],
      isEmpty,
    );
    expect(
      (await me('DELETE', '/social/requests/carol')).status,
      404,
      reason: 'a dropped row cannot be withdrawn',
    );
    expect(
      (await me('POST', '/social/requests', body: '{"to":"carol"}')).status,
      200,
      reason: 'nothing moves',
    );
    // Withdraw a live one; unfriend both rows.
    await as('carol', 'POST', '/social/requests', body: '{"to":"bob"}');
    expect((await as('carol', 'DELETE', '/social/requests/bob')).status, 204);
    expect(gw.social.relation('carol', 'bob'), isNull);
    expect((await me('DELETE', '/social/friends/bob')).status, 204);
    expect(gw.social.relation('bob', 'alice'), isNull);
    expect((await me('DELETE', '/social/friends/bob')).status, 404);
    // Mutual requests settle at once.
    await me('POST', '/social/requests', body: '{"to":"bob"}');
    r = await as('bob', 'POST', '/social/requests', body: '{"to":"alice"}');
    expect(r.status, 200, reason: 'nothing new was requested');
    expect(r.json['state'], 'friends');
    expect(gw.social.relation('bob', 'alice'), 'friends');
  });

  test(
    'blocks drop the peer row, keep a cooldown, never touch their block',
    () async {
      await me('PUT', '/social/me/profile', body: '{"displayName":"Alice"}');
      expect((await me('PUT', '/social/blocks/alice')).status, 400);
      // A block may name anyone, card or not.
      expect((await me('PUT', '/social/blocks/nobody')).status, 204);
      expect(
        (await me('PUT', '/social/blocks/nobody')).status,
        204,
        reason: 'idempotent',
      );
      expect(
        ((await me('GET', '/social/blocks')).json['blocks'] as List<Object?>)
            .single,
        {
          'owner': 'nobody',
          'displayName': null,
          'avatar': null,
          'since': now.millisecondsSinceEpoch ~/ 1000,
        },
      );
      // Blocked by the target: the same 404 as no card.
      await as('bob', 'PUT', '/social/blocks/alice');
      expect(
        (await me('POST', '/social/requests', body: '{"to":"bob"}')).reason,
        'not_found',
      );
      expect(
        (await me('GET', '/social/profiles?ids=bob')).json['profiles'],
        hasLength(1),
        reason: 'a blocker is not hidden',
      );
      // I blocked them: 409 blocked; my block does not clear theirs.
      await me('PUT', '/social/blocks/bob');
      expect(gw.social.relation('bob', 'alice'), 'blocked');
      expect(
        (await me('POST', '/social/requests', body: '{"to":"carol"}')).status,
        201,
      );
      await as('carol', 'POST', '/social/requests/alice/decline');
      // Block over a dropped row keeps the cooldown; unblock restores it.
      await me('PUT', '/social/blocks/carol');
      expect(gw.social.relation('alice', 'carol'), 'blocked');
      expect((await me('DELETE', '/social/blocks/carol')).status, 204);
      expect(gw.social.relation('alice', 'carol'), 'dropped');
      expect((await me('DELETE', '/social/blocks/carol')).status, 404);
      // A block drops a friendship; an unblock does not restore it.
      await as('bob', 'DELETE', '/social/blocks/alice');
      await me('DELETE', '/social/blocks/bob');
      await me('POST', '/social/requests', body: '{"to":"bob"}');
      await as('bob', 'POST', '/social/requests/alice/accept');
      await me('PUT', '/social/blocks/bob');
      expect(gw.social.relation('bob', 'alice'), isNull);
      await me('DELETE', '/social/blocks/bob');
      expect(gw.social.relation('alice', 'bob'), isNull);
      // Deleting my card takes my relations, except others' blocks of me.
      await as('carol', 'PUT', '/social/blocks/alice');
      await me('PUT', '/social/blocks/nobody');
      expect((await me('DELETE', '/social/me/profile')).status, 204);
      expect(gw.social.relation('alice', 'nobody'), isNull);
      expect(gw.social.relation('carol', 'alice'), 'blocked');
      expect((await me('DELETE', '/social/me/profile')).status, 404);
    },
  );

  test(
    'the server key reads anyone, writes cards, deletes relations',
    () async {
      await me('PUT', '/social/me/profile', body: '{"displayName":"Alice"}');
      await me('POST', '/social/requests', body: '{"to":"bob"}');
      await as('bob', 'POST', '/social/requests/alice/accept');
      await me('POST', '/social/requests', body: '{"to":"carol"}');
      final friends = await as(server, 'GET', '/social/u/alice/friends');
      expect(friends.json['owner'], 'alice');
      expect(
        ((friends.json['friends'] as List<Object?>).single! as Map)['owner'],
        'bob',
      );
      expect((await me('GET', '/social/u/alice/friends')).status, 403);
      expect(
        (await as(
          server,
          'POST',
          '/social/requests',
          body: '{"to":"bob"}',
        )).status,
        403,
        reason: 'never creates',
      );
      var r = await as(server, 'DELETE', '/social/u/alice/relations/bob');
      expect(r.json['deleted'], 2);
      r = await as(server, 'DELETE', '/social/u/alice/relations');
      expect(r.json['deleted'], 1);
      expect(
        (await as(server, 'DELETE', '/social/u/alice/profile')).status,
        204,
      );
      expect(
        (await as(server, 'DELETE', '/social/u/alice/profile')).status,
        404,
      );
      expect((await me('GET', '/social/nope')).status, 404);
      expect((await me('POST', '/social/friends')).status, 405);
    },
  );
}
