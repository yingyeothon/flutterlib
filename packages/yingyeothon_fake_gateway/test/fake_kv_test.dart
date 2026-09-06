// Drives the fake's `/kv/*` routes with a raw dart:io HttpClient, so the
// fake is tested against the wire contract (`services/state/README.md`,
// _KV routes_), not against the client library it exists to test.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

final class Answer {
  Answer(this.status, this.headers, this.body);
  final int status;
  final HttpHeaders headers;
  final String body;

  Object? get json => body.isEmpty ? null : Json.decode(body);
  JsonObject get error => (json! as JsonObject).getObject('error')!;
  String? get etag => headers.value('etag');
}

final class Raw {
  Raw(this.origin);
  final Uri origin;
  final HttpClient client = HttpClient();

  Future<Answer> call(
    String method,
    String path, {
    String? token = 'alice',
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    final request = await client.openUrl(method, origin.resolve(path));
    if (token != null) request.headers.set('authorization', 'Bearer $token');
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    final text = await response.transform<String>(utf8.decoder).join();
    return Answer(response.statusCode, response.headers, text);
  }

  void close() => client.close();
}

void main() {
  late FakeGateway gw;
  late Raw raw;

  setUp(() async {
    gw = await FakeGateway.start(
      options: const FakeGatewayOptions(
        kvCollections: <FakeKvCollection>[
          FakeKvCollection(
            name: 'announcements',
            readScope: 'project',
            writeScope: 'team',
            entries: <String, Object?>{
              '2026-09-01': <String, Object?>{'title': 'Welcome'},
              '2026-09-06': <String, Object?>{'title': 'Season 2'},
            },
          ),
          FakeKvCollection(
            name: 'profile',
            id: 'kv_01h455vb4pex5vsknk084sn02q',
            readScope: 'user',
            writeScope: 'user',
            maxEntries: 10,
            maxEntriesPerOwner: 2,
            ownerEntries: <String, Map<String, Object?>>{
              'bob': <String, Object?>{
                'settings': <String, Object?>{'v': 1},
              },
            },
          ),
          FakeKvCollection(name: 'shared', maxEntries: 2),
          FakeKvCollection(name: 'kv_foo'),
          FakeKvCollection(
            name: 'secrets',
            readScope: 'team',
            writeScope: 'team',
          ),
          FakeKvCollection(
            name: 'inbox',
            readScope: 'team',
            writeScope: 'project',
          ),
        ],
      ),
    );
    raw = Raw(gw.kvUrl);
  });

  tearDown(() async {
    raw.close();
    await gw.shutdown();
  });

  test(
    'meta by name, by id, case-folded; team-only is 403; else 404',
    () async {
      final byName = await raw.call('GET', '/kv/Announcements');
      expect(byName.status, 200);
      expect(byName.json, <String, Object?>{
        'id': 'kv_announcements0000000000000',
        'name': 'announcements',
        'readScope': 'project',
        'writeScope': 'team',
        'encrypted': false,
        'maxEntries': 10000,
        'maxEntriesPerOwner': 100,
      });
      expect(byName.headers.value('cache-control'), 'no-store');
      final byId = await raw.call('GET', '/kv/kv_01h455vb4pex5vsknk084sn02q');
      expect(byId.status, 200);
      expect((byId.json! as JsonObject)['name'], 'profile');
      expect((await raw.call('GET', '/kv/secrets')).status, 403);
      expect((await raw.call('GET', '/kv/nope')).status, 404);
      expect(
        (await raw.call('GET', '/kv/kv_01h455vb4pex5vsknk084sn02z')).status,
        404,
      );
      expect(
        (await raw.call('GET', '/kv/KV_shape')).status,
        404,
        reason: 'id shape',
      );
      expect((await raw.call('GET', '/kv/has%20space')).status, 404);
      expect(
        (await raw.call('GET', '/kv/kv_foo')).status,
        200,
        reason: 'a legal name',
      );
      expect((await raw.call('GET', '/kv/shared/nope')).status, 404);
      expect((await raw.call('POST', '/kv/shared')).status, 405);
    },
  );

  test('a missing or refused bearer is 401', () async {
    final missing = await raw.call('GET', '/kv/shared', token: null);
    expect(missing.status, 401);
    expect(missing.error['code'], 'unauthorized');
    final empty = await raw.call('GET', '/kv/shared', token: '');
    expect(empty.status, 401);
    final strict = await FakeGateway.start(
      options: const FakeGatewayOptions(
        acceptedTokens: <String>{'ok'},
        kvCollections: <FakeKvCollection>[FakeKvCollection(name: 'c')],
      ),
    );
    addTearDown(strict.shutdown);
    final other = Raw(strict.kvUrl);
    addTearDown(other.close);
    expect((await other.call('GET', '/kv/c', token: 'bad')).status, 401);
    expect((await other.call('GET', '/kv/c', token: 'ok')).status, 200);
  });

  test(
    'announcements: a player lists with values, desc, and cannot write',
    () async {
      final page = await raw.call(
        'GET',
        '/kv/announcements/entries?values=1&order=desc',
      );
      expect(page.status, 200);
      final entries = (page.json! as JsonObject).getListOrEmpty('entries');
      expect(entries.map((e) => (e! as JsonObject)['key']), <String>[
        '2026-09-06',
        '2026-09-01',
      ]);
      final first = entries.first! as JsonObject;
      expect(first.containsKey('owner'), isFalse);
      expect(first['version'], 1);
      expect(first['bytes'], 20);
      expect(first['expiresAt'], isNull);
      expect(first['updatedAt'], isA<int>());
      expect(first['valueText'], '{"title":"Season 2"}');
      expect((page.json! as JsonObject).containsKey('nextCursor'), isFalse);

      final one = await raw.call('GET', '/kv/announcements/entries/2026-09-01');
      expect(one.status, 200);
      expect(one.body, '{"title":"Welcome"}');
      expect(one.etag, '"1"');
      expect(one.headers.value('x-kv-expires-at'), isNull);

      final write = await raw.call(
        'PUT',
        '/kv/announcements/entries/x',
        body: '1',
      );
      expect(write.status, 403);
      expect(write.error['code'], 'forbidden');
    },
  );

  test(
    'profile: me is the player; another owner is 403; wrong namespace 400',
    () async {
      final missing = await raw.call(
        'GET',
        '/kv/profile/u/me/entries/settings',
      );
      expect(missing.status, 404);
      expect(missing.error['code'], 'not_found');

      final created = await raw.call(
        'PUT',
        '/kv/profile/u/me/entries/settings?ttl=60',
        headers: <String, String>{'if-none-match': '*'},
        body: '{"volume":0.5}',
      );
      expect(created.status, 201);
      expect(created.etag, '"1"');
      final expires = int.parse(created.headers.value('x-kv-expires-at')!);
      expect(
        expires,
        greaterThan(DateTime.now().millisecondsSinceEpoch ~/ 1000),
      );
      expect(
        gw.kv.valueText('profile', 'settings', owner: 'alice'),
        '{"volume":0.5}',
      );

      final read = await raw.call('GET', '/kv/profile/u/me/entries/settings');
      expect(read.status, 200);
      expect(read.body, '{"volume":0.5}');
      expect(read.etag, '"1"');
      expect(read.headers.value('x-kv-expires-at'), '$expires');

      final again = await raw.call(
        'PUT',
        '/kv/profile/u/me/entries/settings',
        headers: <String, String>{'if-none-match': '*'},
        body: '{}',
      );
      expect(again.status, 409);
      expect(again.error['code'], 'conflict');
      expect(again.error.getObject('details'), <String, Object?>{'current': 1});

      final stale = await raw.call(
        'PUT',
        '/kv/profile/u/me/entries/settings',
        headers: <String, String>{'if-match': '"5"'},
        body: '{}',
      );
      expect(stale.status, 409);
      expect(stale.error.getObject('details'), <String, Object?>{'current': 1});

      final updated = await raw.call(
        'PUT',
        '/kv/profile/u/me/entries/settings',
        headers: <String, String>{'if-match': 'W/"1"'},
        body: '{"volume":1}',
      );
      expect(updated.status, 204);
      expect(updated.etag, '"2"');
      expect(
        updated.headers.value('x-kv-expires-at'),
        isNull,
        reason: 'a keep write says nothing about the expiry',
      );
      final kept = await raw.call('GET', '/kv/profile/u/me/entries/settings');
      expect(kept.headers.value('x-kv-expires-at'), '$expires', reason: 'kept');
      final cleared = await raw.call(
        'PUT',
        '/kv/profile/u/me/entries/settings?ttl=0',
        body: '{"volume":1}',
      );
      expect(cleared.status, 204);
      final noExpiry = await raw.call(
        'GET',
        '/kv/profile/u/me/entries/settings',
      );
      expect(noExpiry.headers.value('x-kv-expires-at'), isNull);

      final list = await raw.call('GET', '/kv/profile/u/me/entries');
      final rows = (list.json! as JsonObject).getListOrEmpty('entries');
      expect(rows, hasLength(1));
      expect((rows.single! as JsonObject)['owner'], 'alice');
      expect((rows.single! as JsonObject).containsKey('valueText'), isFalse);

      expect(
        (await raw.call('GET', '/kv/profile/u/bob/entries/settings')).status,
        403,
      );
      expect((await raw.call('GET', '/kv/profile/u/bob/entries')).status, 403);
      expect(
        (await raw.call('GET', '/kv/profile/entries')).status,
        403,
        reason: 'every owner',
      );
      final wrong = await raw.call('GET', '/kv/profile/entries/settings');
      expect(wrong.status, 400);
      expect(wrong.error.getObject('details'), <String, Object?>{
        'reason': 'wrong_namespace',
      });
      final shared = await raw.call('GET', '/kv/shared/u/me/entries/k');
      expect(shared.status, 400);
      expect(shared.error.getObject('details'), <String, Object?>{
        'reason': 'wrong_namespace',
      });
      expect((await raw.call('GET', '/kv/profile/u/Bad!/entries')).status, 400);
      expect((await raw.call('GET', '/kv/profile/u/me/nope')).status, 404);
      expect(
        (await raw.call('GET', '/kv/profile/u/me/entries/k/extra')).status,
        404,
      );
      expect(
        (await raw.call('GET', '/kv/profile/u/me/entries/.bad')).status,
        400,
      );
      expect(
        (await raw.call('POST', '/kv/profile/u/me/entries/k')).status,
        405,
      );
      expect((await raw.call('PUT', '/kv/profile/u/me/entries')).status, 405);
    },
  );

  test(
    'a server key reads and writes any owner; me is refused for it',
    () async {
      const server = 'yds.auth_0123456789abcdef.k';
      final bob = await raw.call(
        'GET',
        '/kv/profile/u/bob/entries/settings',
        token: server,
      );
      expect(bob.status, 200);
      expect(bob.body, '{"v":1}');
      final all = await raw.call('GET', '/kv/profile/entries', token: server);
      expect(all.status, 200);
      expect(
        (all.json! as JsonObject)
            .getListOrEmpty('entries')
            .map((e) => (e! as JsonObject)['owner']),
        <String>['bob'],
      );
      expect(
        (await raw.call(
          'PUT',
          '/kv/profile/u/github:octocat/entries/k',
          token: server,
          body: '1',
        )).status,
        201,
      );
      expect(
        (await raw.call(
          'GET',
          '/kv/profile/u/me/entries',
          token: server,
        )).status,
        400,
      );
    },
  );

  test(
    'write-only: 204 without an ETag, conditional is 403, delete 204',
    () async {
      final put = await raw.call('PUT', '/kv/inbox/entries/k', body: '"v"');
      expect(put.status, 204);
      expect(put.etag, isNull);
      final again = await raw.call('PUT', '/kv/inbox/entries/k', body: '"w"');
      expect(again.status, 204);
      final conditional = await raw.call(
        'PUT',
        '/kv/inbox/entries/k',
        headers: <String, String>{'if-match': '"2"'},
        body: '"x"',
      );
      expect(conditional.status, 403);
      final deleteConditional = await raw.call(
        'DELETE',
        '/kv/inbox/entries/k',
        headers: <String, String>{'if-match': '"2"'},
      );
      expect(deleteConditional.status, 403);
      expect((await raw.call('GET', '/kv/inbox/entries/k')).status, 403);
      expect(
        (await raw.call(
          'PATCH',
          '/kv/inbox/entries/k',
          body: '{"incr":1}',
        )).status,
        403,
      );
      expect((await raw.call('DELETE', '/kv/inbox/entries/k')).status, 204);
      expect((await raw.call('DELETE', '/kv/inbox/entries/never')).status, 204);
    },
  );

  test('bad requests: body, ttl, conditions, size', () async {
    expect(
      (await raw.call('PUT', '/kv/shared/entries/k', body: 'not json')).status,
      400,
    );
    expect(
      (await raw.call('PUT', '/kv/shared/entries/k?ttl=-1', body: '1')).status,
      400,
    );
    expect(
      (await raw.call('PUT', '/kv/shared/entries/k?ttl=x', body: '1')).status,
      400,
    );
    expect(
      (await raw.call(
        'PUT',
        '/kv/shared/entries/k?ttl=${366 * 86400 + 1}',
        body: '1',
      )).status,
      400,
    );
    expect(
      (await raw.call(
        'PUT',
        '/kv/shared/entries/k',
        headers: <String, String>{'if-match': '"1"', 'if-none-match': '*'},
        body: '1',
      )).status,
      400,
    );
    expect(
      (await raw.call(
        'PUT',
        '/kv/shared/entries/k',
        headers: <String, String>{'if-match': '"0"'},
        body: '1',
      )).status,
      400,
    );
    expect(
      (await raw.call(
        'PUT',
        '/kv/shared/entries/k',
        headers: <String, String>{'if-match': 'abc'},
        body: '1',
      )).status,
      400,
    );
    expect(
      (await raw.call(
        'PUT',
        '/kv/shared/entries/k',
        headers: <String, String>{'if-none-match': '"1"'},
        body: '1',
      )).status,
      400,
    );
    final big = await raw.call(
      'PUT',
      '/kv/shared/entries/k',
      body: '"${'x' * (16 * 1024)}"',
    );
    expect(big.status, 413);
    final fits = await raw.call(
      'PUT',
      '/kv/shared/entries/k',
      body: '"${'x' * (16 * 1024 - 2)}"',
    );
    expect(fits.status, 201);
  });

  test('caps: collection_full and owner_full on create only', () async {
    expect(
      (await raw.call('PUT', '/kv/shared/entries/a', body: '1')).status,
      201,
    );
    expect(
      (await raw.call('PUT', '/kv/shared/entries/b', body: '1')).status,
      201,
    );
    final full = await raw.call('PUT', '/kv/shared/entries/c', body: '1');
    expect(full.status, 409);
    expect(full.error.getObject('details'), <String, Object?>{
      'reason': 'collection_full',
    });
    expect(
      (await raw.call('PUT', '/kv/shared/entries/a', body: '2')).status,
      204,
      reason: 'an update',
    );
    expect(
      (await raw.call('PUT', '/kv/profile/u/me/entries/a', body: '1')).status,
      201,
    );
    expect(
      (await raw.call('PUT', '/kv/profile/u/me/entries/b', body: '1')).status,
      201,
    );
    final owner = await raw.call(
      'PUT',
      '/kv/profile/u/me/entries/c',
      body: '1',
    );
    expect(owner.status, 409);
    expect(owner.error.getObject('details'), <String, Object?>{
      'reason': 'owner_full',
    });
    // The per-owner cap bounds a player; the server key is not a player.
    final server = await raw.call(
      'PUT',
      '/kv/profile/u/alice/entries/c',
      token: 'yds.auth_0123456789abcdef.k',
      body: '1',
    );
    expect(server.status, 201);
  });

  test(
    'incr: from zero, on a number, not_a_number, overflow, no conditions',
    () async {
      final first = await raw.call(
        'PATCH',
        '/kv/shared/entries/hits',
        body: '{"incr":2}',
      );
      expect(first.status, 200);
      expect(first.json, <String, Object?>{'value': 2, 'version': 1});
      expect(first.etag, '"1"');
      final whole = await raw.call(
        'PATCH',
        '/kv/shared/entries/hits',
        body: '{"incr":1.0}',
      );
      expect(whole.status, 200, reason: 'a whole double is an integer');
      expect((whole.json! as JsonObject)['value'], 3);
      expect(
        (await raw.call(
          'PATCH',
          '/kv/shared/entries/hits',
          body: '{"incr":-1}',
        )).status,
        200,
      );
      final second = await raw.call(
        'PATCH',
        '/kv/shared/entries/hits?ttl=60',
        body: '{"incr":-5}',
      );
      expect(second.json, <String, Object?>{'value': -3, 'version': 4});
      final read = await raw.call('GET', '/kv/shared/entries/hits');
      expect(read.body, '-3');
      expect(read.headers.value('x-kv-expires-at'), isNotNull);
      await raw.call('PUT', '/kv/shared/entries/text', body: '"t"');
      final text = await raw.call(
        'PATCH',
        '/kv/shared/entries/text',
        body: '{"incr":1}',
      );
      expect(text.status, 409);
      expect(text.error.getObject('details'), <String, Object?>{
        'reason': 'not_a_number',
      });
      await raw.call(
        'PUT',
        '/kv/shared/entries/hits',
        body: '9007199254740990',
      );
      final over = await raw.call(
        'PATCH',
        '/kv/shared/entries/hits',
        body: '{"incr":2}',
      );
      expect(over.status, 409);
      expect(over.error.getObject('details'), <String, Object?>{
        'reason': 'overflow',
      });
      expect(
        (await raw.call(
          'PATCH',
          '/kv/shared/entries/hits',
          body: '{"incr":1.5}',
        )).status,
        400,
      );
      expect(
        (await raw.call('PATCH', '/kv/shared/entries/hits', body: '[]')).status,
        400,
      );
      expect(
        (await raw.call(
          'PATCH',
          '/kv/shared/entries/hits',
          headers: <String, String>{'if-match': '"1"'},
          body: '{"incr":1}',
        )).status,
        400,
      );
    },
  );

  test(
    'delete removes the row; a stale If-Match is 409, a missing key 404',
    () async {
      await raw.call('PUT', '/kv/shared/entries/k', body: '1');
      await raw.call('PUT', '/kv/shared/entries/k', body: '2');
      final stale = await raw.call(
        'DELETE',
        '/kv/shared/entries/k',
        headers: <String, String>{'if-match': '"1"'},
      );
      expect(stale.status, 409);
      expect(stale.error.getObject('details'), <String, Object?>{'current': 2});
      expect(
        (await raw.call(
          'DELETE',
          '/kv/shared/entries/k',
          headers: <String, String>{'if-match': '"2"'},
        )).status,
        204,
      );
      expect((await raw.call('GET', '/kv/shared/entries/k')).status, 404);
      expect(gw.kv.valueText('shared', 'k'), isNull);
      final gone = await raw.call(
        'DELETE',
        '/kv/shared/entries/k',
        headers: <String, String>{'if-match': '"2"'},
      );
      expect(
        gone.status,
        404,
        reason: 'missing is reported before the version',
      );
      expect((await raw.call('DELETE', '/kv/shared/entries/k')).status, 404);
      final reborn = await raw.call('PUT', '/kv/shared/entries/k', body: '3');
      expect(reborn.status, 201);
      expect(
        reborn.etag,
        '"1"',
        reason: 'a deleted row is gone; only expiry keeps a version',
      );
      expect(
        (await raw.call(
          'GET',
          '/kv/shared/entries/k',
        )).headers.value('x-kv-expires-at'),
        isNull,
      );
    },
  );

  test('list: prefix, limit, cursor, order, bad parameters', () async {
    for (final key in <String>['a1', 'a2', 'a3', 'b1']) {
      await raw
          .call('PUT', '/kv/profile/u/me/entries/$key', body: '"$key"')
          .then((a) => expect(a.status, anyOf(201, 409)));
    }
    // maxEntriesPerOwner is 2, so only a1 and a2 landed.
    final page1 = await raw.call(
      'GET',
      '/kv/profile/u/me/entries?limit=1&prefix=a',
    );
    final body1 = page1.json! as JsonObject;
    expect(
      body1.getListOrEmpty('entries').map((e) => (e! as JsonObject)['key']),
      <String>['a1'],
    );
    expect(body1['nextCursor'], '1');
    final page2 = await raw.call(
      'GET',
      '/kv/profile/u/me/entries?limit=1&prefix=a&cursor=1',
    );
    final body2 = page2.json! as JsonObject;
    expect(
      body2.getListOrEmpty('entries').map((e) => (e! as JsonObject)['key']),
      <String>['a2'],
    );
    expect(body2.containsKey('nextCursor'), isFalse);
    final desc = await raw.call(
      'GET',
      '/kv/profile/u/me/entries?order=desc&values=true',
    );
    final rows = (desc.json! as JsonObject).getListOrEmpty('entries');
    expect(rows.map((e) => (e! as JsonObject)['key']), <String>['a2', 'a1']);
    expect((rows.first! as JsonObject)['valueText'], '"a2"');
    // The server clamps the limit and refuses a prefix outside the key grammar.
    expect((await raw.call('GET', '/kv/shared/entries?limit=0')).status, 200);
    expect((await raw.call('GET', '/kv/shared/entries?limit=101')).status, 200);
    expect((await raw.call('GET', '/kv/shared/entries?limit=abc')).status, 200);
    expect(
      (await raw.call('GET', '/kv/shared/entries?prefix=a/b')).status,
      400,
    );
    expect((await raw.call('GET', '/kv/shared/entries?order=up')).status, 400);
    expect((await raw.call('GET', '/kv/shared/entries?cursor=x')).status, 400);
    expect(
      (await raw.call(
        'GET',
        '/kv/shared/entries?limit=&order=&cursor=',
      )).status,
      200,
    );
  });

  test('a ttl of one second expires the row for every read', () async {
    final put = await raw.call(
      'PUT',
      '/kv/shared/entries/soon?ttl=1',
      body: '1',
    );
    expect(put.status, 201);
    expect(gw.kv.valueText('shared', 'soon'), '1');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect((await raw.call('GET', '/kv/shared/entries/soon')).status, 404);
    expect(gw.kv.valueText('shared', 'soon'), isNull);
    final list = await raw.call('GET', '/kv/shared/entries');
    expect((list.json! as JsonObject).getListOrEmpty('entries'), isEmpty);
    final reborn = await raw.call('PUT', '/kv/shared/entries/soon', body: '2');
    expect(reborn.status, 201);
    expect(reborn.etag, '"2"');
    expect(gw.kv.valueText('nope', 'x'), isNull);
  });
}
