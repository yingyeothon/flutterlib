import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_kvstore_client/yingyeothon_kvstore_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'fake_http_client.dart';

/// Captures formatted lines.
final class CapturingLogWriter implements LogWriter {
  final List<String> lines = <String>[];
  void _add(LogSeverity s, String m, JsonObject? c) =>
      lines.add(LogWriters.format(s, m, c));
  @override
  void debug(String message, [JsonObject? context]) =>
      _add(LogSeverity.debug, message, context);
  @override
  void info(String message, [JsonObject? context]) =>
      _add(LogSeverity.info, message, context);
  @override
  void warn(String message, [JsonObject? context]) =>
      _add(LogSeverity.warn, message, context);
  @override
  void error(String message, [JsonObject? context]) =>
      _add(LogSeverity.error, message, context);
}

/// Runs [body] and returns the [KvStoreException] it threw, asserting that
/// its string is the code-and-status template and nothing else.
Future<KvStoreException> refused(Future<Object?> Function() body) async {
  try {
    await body();
  } on KvStoreException catch (e) {
    expect(e.toString(), 'KvStoreException(${e.code}, ${e.status})');
    return e;
  }
  fail('expected a KvStoreException');
}

void main() {
  late FakeHttp fake;
  late CapturingLogWriter log;
  late KvStoreClient client;

  setUp(() {
    fake = FakeHttp();
    log = CapturingLogWriter();
    client = KvStoreClient(
      KvStoreClientOptions(
        baseUrl: Uri.parse('https://doc.example'),
        token: fixtureToken,
        client: fake,
        logger: createFilteredLogger(severity: LogSeverity.debug, writer: log),
      ),
    );
  });

  group('options', () {
    test('refuse a relative or non-http base URL and an empty token', () {
      KvStoreClientOptions options(Uri url, [String token = 't']) =>
          KvStoreClientOptions(baseUrl: url, token: token, client: fake);
      expect(
        () => KvStoreClient(options(Uri.parse('/kv'))),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'kv baseUrl must be an absolute http(s) URL with no user info, query or fragment',
          ),
        ),
      );
      expect(
        () => KvStoreClient(options(Uri.parse('wss://doc.example'))),
        throwsArgumentError,
      );
      expect(
        () => KvStoreClient(options(Uri.parse('https://doc.example'), '')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'kv token is required',
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('close closes an owned client only, once', () {
      client.close();
      client.close();
      expect(fake.closed, isFalse, reason: 'injected, so left to its owner');
    });

    test('a base URL with a path keeps it', () async {
      final nested = KvStoreClient(
        KvStoreClientOptions(
          baseUrl: Uri.parse('https://h.example/api/'),
          token: 't',
          client: fake,
        ),
      );
      fake.answer(200, '{"entries":[]}');
      await nested.collection('c').list();
      expect(fake.single.url.toString(), 'https://h.example/api/kv/c/entries');
    });
  });

  group('collection', () {
    test('a kv_ id and a name pass; anything else is refused at once', () {
      expect(
        client.collection('kv_01h455vb4pex5vsknk084sn02q').ref,
        'kv_01h455vb4pex5vsknk084sn02q',
      );
      expect(client.collection('announcements').ref, 'announcements');
      expect(client.collection('a.b-c_d').ref, 'a.b-c_d');
      for (final bad in <String>[
        '',
        '-lead',
        'has space',
        'has/slash',
        'x' * 65,
        'ünïcode',
      ]) {
        expect(
          () => client.collection(bad),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'kv collection must be a kv_ id or a name matching '
                  '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\$',
            ),
          ),
          reason: bad,
        );
      }
      expect(fake.requests, isEmpty);
    });

    test('info reads the shape and keeps raw', () async {
      fake.answer(
        200,
        '{"id":"kv_01h455vb4pex5vsknk084sn02q","name":"profile","readScope":"user",'
        '"writeScope":"user","encrypted":true,"maxEntries":10000,'
        '"maxEntriesPerOwner":100,"extra":1}',
      );
      final info = await client.collection('profile').info();
      final request = fake.single;
      expect(request.method, 'GET');
      expect(request.url.toString(), 'https://doc.example/kv/profile');
      expect(request.headers['authorization'], 'Bearer $fixtureToken');
      expect(request.headers['accept'], 'application/json');
      expect(request.headers.containsKey('content-type'), isFalse);
      expect(info.id, 'kv_01h455vb4pex5vsknk084sn02q');
      expect(info.name, 'profile');
      expect(info.readScope, KvScope.user);
      expect(info.writeScope, KvScope.user);
      expect(info.isUserNamespace, isTrue);
      expect(info.encrypted, isTrue);
      expect(info.maxEntries, 10000);
      expect(info.maxEntriesPerOwner, 100);
      expect(info.raw['extra'], 1);
    });

    test(
      'info: missing fields read as empty, a non-object is malformed',
      () async {
        fake.answer(200, '{}');
        final info = await client.collection('c').info();
        expect(info.readScope, '');
        expect(info.encrypted, isFalse);
        expect(info.maxEntries, 0);
        expect(info.isUserNamespace, isFalse);
        fake.answer(200, '[]');
        final e = await refused(() => client.collection('c').info());
        expect(e.code, KvStoreException.malformedResponseCode);
        expect(e.status, 200);
      },
    );

    test('info: 403 when both scopes are team', () async {
      fake.answer(403, '{"error":{"code":"forbidden","message":"team only"}}');
      final e = await refused(() => client.collection('secrets').info());
      expect(e.status, 403);
      expect(e.code, 'forbidden');
      expect(e.isForbidden, isTrue);
      expect(e.isConflict, isFalse);
    });

    test(
      'mine and owner build the user-namespace path; owner is checked',
      () async {
        final col = client.collection('profile');
        fake.answer(200, '{"entries":[]}');
        await col.mine.list();
        expect(fake.requests.last.url.path, '/kv/profile/u/me/entries');
        fake.answer(200, '{"entries":[]}');
        await col.owner('0123456789abcdef0123456789abcdef').list();
        expect(
          fake.requests.last.url.path,
          '/kv/profile/u/0123456789abcdef0123456789abcdef/entries',
        );
        fake.answer(200, '{"entries":[]}');
        await col.owner('github:octocat').list();
        expect(
          fake.requests.last.url.path,
          '/kv/profile/u/github:octocat/entries',
        );
        for (final bad in <String>['', 'me/../x', 'ME', 'GitHub:x', 'a b']) {
          expect(
            () => col.owner(bad),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                'kv owner must be me, 32 hex characters, or kind:id',
              ),
            ),
            reason: bad,
          );
        }
        expect(identical(col.mine, col.mine), isTrue);
      },
    );
  });

  group('get and getEntry', () {
    test('a stored value with its version and expiry', () async {
      fake.answer(200, '{"volume":0.5}', <String, String>{
        'ETag': '"3"',
        'X-KV-Expires-At': '1700000000',
      });
      final entry = await client
          .collection('profile')
          .mine
          .getEntry('settings');
      expect(fake.single.method, 'GET');
      expect(
        fake.single.url.toString(),
        'https://doc.example/kv/profile/u/me/entries/settings',
      );
      expect(entry!.value, <String, Object?>{'volume': 0.5});
      expect(entry.version, 3);
      expect(entry.expiresAt, 1700000000);
    });

    test('get returns the value; a stored null is null, not absent', () async {
      fake.answer(200, 'null', <String, String>{'etag': 'W/"7"'});
      expect(await client.collection('c').get('k'), isNull);
      fake.answer(200, '"text"', <String, String>{'etag': '7'});
      expect(await client.collection('c').get('k'), 'text');
      fake.answer(200, 'null', <String, String>{'etag': '"1"'});
      final entry = await client.collection('c').getEntry('k');
      expect(entry, isNotNull);
      expect(entry!.value, isNull);
      expect(entry.expiresAt, isNull);
    });

    test(
      '404: getEntry is null; get calls orElse or throws not_found',
      () async {
        fake.answer(
          404,
          '{"error":{"code":"not_found","message":"entry not found"}}',
        );
        expect(await client.collection('c').getEntry('k'), isNull);
        fake.answer(404, '');
        expect(
          await client.collection('c').get('k', orElse: () => null),
          isNull,
        );
        fake.answer(404, '');
        expect(await client.collection('c').get('k', orElse: () => 42), 42);
        fake.answer(404, '');
        final e = await refused(() => client.collection('c').get('k'));
        expect(e.status, 404);
        expect(e.code, KvStoreException.notFoundCode);
        expect(e.isNotFound, isTrue);
      },
    );

    test('a 200 without a version, or a non-JSON body, is malformed', () async {
      fake.answer(200, '{}');
      var e = await refused(() => client.collection('c').getEntry('k'));
      expect(e.code, KvStoreException.malformedResponseCode);
      fake.answer(200, 'not json', <String, String>{'etag': '"1"'});
      e = await refused(() => client.collection('c').getEntry('k'));
      expect(e.code, KvStoreException.malformedResponseCode);
      fake.answer(200, '{}', <String, String>{'etag': 'v1'});
      e = await refused(() => client.collection('c').getEntry('k'));
      expect(e.code, KvStoreException.malformedResponseCode);
    });

    test('other refusals pass through with the server code', () async {
      fake.answer(403, '{"error":{"code":"forbidden","message":"no"}}');
      var e = await refused(() => client.collection('c').get('k'));
      expect(e.status, 403);
      expect(e.code, 'forbidden');
      fake.answer(401, '{"error":{"code":"unauthorized","message":"x"}}');
      e = await refused(() => client.collection('c').getEntry('k'));
      expect(e.isUnauthorized, isTrue);
      fake.answer(
        503,
        '{"error":{"code":"kv_encryption_not_configured","message":"x"}}',
      );
      e = await refused(() => client.collection('c').getEntry('k'));
      expect(e.status, 503);
      expect(e.code, 'kv_encryption_not_configured');
      fake.answer(500, 'not json');
      e = await refused(() => client.collection('c').getEntry('k'));
      expect(e.code, 'http_500');
      expect(e.reason, isNull);
      expect(e.hasCurrentVersion, isFalse);
    });

    test('the key grammar is refused before any request', () {
      for (final bad in <String>['', '.lead', 'a/b', 'a@b', 'k' * 129, '한글']) {
        expect(
          () => client.collection('c').get(bad),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'kv key must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\$',
            ),
          ),
          reason: bad,
        );
      }
      expect(fake.requests, isEmpty);
    });
  });

  group('put', () {
    test('sends JSON with the conditions and reads the write back', () async {
      fake.answer(201, '', <String, String>{
        'etag': '"1"',
        'x-kv-expires-at': '1700000060',
      });
      final result = await client
          .collection('profile')
          .mine
          .put(
            'settings',
            <String, Object?>{'volume': 0.5, 'n': null},
            ttl: 60,
            ifNoneMatch: true,
          );
      final request = fake.single;
      expect(request.method, 'PUT');
      expect(
        request.url.toString(),
        'https://doc.example/kv/profile/u/me/entries/settings?ttl=60',
      );
      expect(request.headers['content-type'], 'application/json');
      expect(request.headers['if-none-match'], '*');
      expect(request.headers.containsKey('if-match'), isFalse);
      expect(request.body, '{"volume":0.5,"n":null}');
      expect(result.created, isTrue);
      expect(result.version, 1);
      expect(result.expiresAt, 1700000060);
    });

    test('if-match is quoted; 204 is an update; ttl 0 clears', () async {
      fake.answer(204, '', <String, String>{'etag': '"4"'});
      final result = await client
          .collection('c')
          .put('k', 1, ifMatch: 3, ttl: 0);
      expect(fake.single.headers['if-match'], '"3"');
      expect(fake.single.url.query, 'ttl=0');
      expect(fake.single.body, '1');
      expect(result.created, isFalse);
      expect(result.version, 4);
      expect(result.expiresAt, isNull);
    });

    test('a write-only caller learns nothing', () async {
      fake.answer(204, '');
      final result = await client.collection('inbox').put('k', 'v');
      expect(fake.single.url.hasQuery, isFalse);
      expect(result.created, isNull);
      expect(result.version, isNull);
      expect(result.expiresAt, isNull);
    });

    test('409: the live version, null for absent, or a reason', () async {
      fake.answer(
        409,
        '{"error":{"code":"conflict","message":"version mismatch","details":{"current":5}}}',
      );
      var e = await refused(
        () => client.collection('c').put('k', 1, ifMatch: 3),
      );
      expect(e.isConflict, isTrue);
      expect(e.isVersionMismatch, isTrue);
      expect(e.hasCurrentVersion, isTrue);
      expect(e.currentVersion, 5);
      expect(e.isFull, isFalse);
      fake.answer(
        409,
        '{"error":{"code":"conflict","message":"version mismatch","details":{"current":null}}}',
      );
      e = await refused(() => client.collection('c').put('k', 1, ifMatch: 3));
      expect(e.hasCurrentVersion, isTrue);
      expect(e.currentVersion, isNull);
      fake.answer(
        409,
        '{"error":{"code":"conflict","message":"version mismatch"}}',
      );
      e = await refused(() => client.collection('c').put('k', 1, ifMatch: 3));
      expect(e.hasCurrentVersion, isFalse, reason: 'a write-only caller');
      expect(e.currentVersion, isNull);
      for (final reason in <String>[
        'collection_full',
        'owner_full',
        'overflow',
      ]) {
        fake.answer(
          409,
          '{"error":{"code":"conflict","message":"x","details":{"reason":"$reason"}}}',
        );
        e = await refused(() => client.collection('c').put('k', 1));
        expect(e.reason, reason);
        expect(e.isFull, reason != 'overflow');
        expect(e.isVersionMismatch, isFalse);
      }
      fake.answer(
        409,
        '{"error":{"code":"conflict","details":{"current":"5"}}}',
      );
      e = await refused(() => client.collection('c').put('k', 1));
      expect(e.hasCurrentVersion, isFalse, reason: 'not a version');
    });

    test('403 on a conditional write without the read right', () async {
      fake.answer(403, '{"error":{"code":"forbidden","message":"x"}}');
      final e = await refused(
        () => client.collection('c').put('k', 1, ifMatch: 1),
      );
      expect(e.isForbidden, isTrue);
    });

    test('400 wrong_namespace names the reason', () async {
      fake.answer(
        400,
        '{"error":{"code":"bad_request","message":"use /u/me","details":{"reason":"wrong_namespace"}}}',
      );
      final e = await refused(() => client.collection('profile').put('k', 1));
      expect(e.status, 400);
      expect(e.reason, 'wrong_namespace');
    });

    test('local refusals throw before any request', () {
      final ns = client.collection('c');
      expect(
        () => ns.put('k', 1, ifMatch: 1, ifNoneMatch: true),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'kv ifMatch and ifNoneMatch cannot be combined',
          ),
        ),
      );
      expect(() => ns.put('k', 1, ifMatch: -1), throwsArgumentError);
      expect(() => ns.put('k', 1, ifMatch: 0), throwsArgumentError);
      expect(() => ns.delete('k', ifMatch: 0), throwsArgumentError);
      expect(() => ns.put('k', 1, ttl: -1), throwsArgumentError);
      expect(
        () => ns.put('k', 1, ttl: KvRules.ttlMaxSeconds + 1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'kv ttl must be 0 or between 1 and ${KvRules.ttlMaxSeconds} seconds',
          ),
        ),
      );
      // 16 KiB of body passes locally; one byte more is refused, measured in
      // UTF-8 bytes, so a 3-byte character counts as three.
      final fits = 'x' * (KvRules.maxValueBytes - 2); // plus the two quotes
      final over =
          '${'한' * ((KvRules.maxValueBytes - 2) ~/ 3)}xxx'; // 16383 + 2 quotes
      expect(KvRules.valueBytes('"$fits"'), KvRules.maxValueBytes);
      expect(KvRules.valueBytes('"$over"'), KvRules.maxValueBytes + 1);
      expect(
        () => ns.put('k', over),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'kv value exceeds ${KvRules.maxValueBytes} bytes',
          ),
        ),
      );
      expect(fake.requests, isEmpty);
      fake.answer(204, '');
      expect(ns.put('k', fits), completes);
    });

    test('a value JSON cannot carry is refused by the codec', () {
      expect(
        () => client.collection('c').put('k', Object()),
        throwsA(isA<JsonEncodeError>()),
      );
      expect(fake.requests, isEmpty);
    });
  });

  group('delete', () {
    test('204 for a present or an absent key; if-match optional', () async {
      fake.answer(204, '');
      await client.collection('c').delete('k');
      expect(fake.single.method, 'DELETE');
      expect(fake.single.url.path, '/kv/c/entries/k');
      expect(fake.single.headers.containsKey('if-match'), isFalse);
      fake.answer(204, '');
      await client.collection('c').mine.delete('k', ifMatch: 2);
      expect(fake.requests.last.headers['if-match'], '"2"');
      expect(fake.requests.last.url.path, '/kv/c/u/me/entries/k');
      fake.answer(409, '{"error":{"code":"conflict","details":{"current":3}}}');
      final e = await refused(() async {
        await client.collection('c').delete('k', ifMatch: 2);
        return null;
      });
      expect(e.currentVersion, 3);
    });
  });

  group('list', () {
    test('every query parameter, encoded', () async {
      fake.answer(200, '{"entries":[]}');
      final page = await client
          .collection('c')
          .list(
            prefix: 'a b&c',
            cursor: 'cur=/+',
            limit: 100,
            order: KvOrder.desc,
            values: true,
          );
      expect(page.entries, isEmpty);
      expect(page.nextCursor, isNull);
      final url = fake.single.url;
      expect(url.path, '/kv/c/entries');
      expect(url.queryParameters, <String, String>{
        'prefix': 'a b&c',
        'cursor': 'cur=/+',
        'limit': '100',
        'order': 'desc',
        'values': '1',
      });
      expect(
        url.query,
        'prefix=a+b%26c&cursor=cur%3D%2F%2B&limit=100&order=desc&values=1',
      );
      fake.answer(200, '{"entries":[]}');
      await client.collection('c').list(limit: 1);
      expect(
        fake.requests.last.url.query,
        'limit=1',
        reason: 'asc is the default and not sent',
      );
    });

    test('rows decode valueText; owner and expiresAt are optional', () async {
      fake.answer(
        200,
        '{"entries":['
        '{"owner":"o1","key":"a","version":2,"bytes":4,"expiresAt":null,"updatedAt":1700000000,"valueText":"null"},'
        '{"key":"b","version":1,"bytes":2,"expiresAt":1700000500,"updatedAt":1700000001,"valueText":"{\\"x\\":1}"},'
        '{"key":"c","version":1,"bytes":2,"updatedAt":1700000002}'
        '],"nextCursor":"n1"}',
      );
      final page = await client.collection('c').list(values: true);
      expect(page.nextCursor, 'n1');
      expect(page.entries, hasLength(3));
      final a = page.entries[0];
      expect(a.owner, 'o1');
      expect(a.key, 'a');
      expect(a.version, 2);
      expect(a.bytes, 4);
      expect(a.expiresAt, isNull);
      expect(a.updatedAt, 1700000000);
      expect(a.hasValue, isTrue);
      expect(a.value, isNull, reason: 'a stored null');
      expect(a.raw['valueText'], 'null');
      final b = page.entries[1];
      expect(b.owner, isNull);
      expect(b.expiresAt, 1700000500);
      expect(b.value, <String, Object?>{'x': 1});
      final c = page.entries[2];
      expect(c.hasValue, isFalse);
      expect(c.value, isNull);
      expect(() => page.entries.clear(), throwsUnsupportedError);
    });

    test('a malformed page or row is malformed_response', () async {
      fake.answer(200, '[]');
      var e = await refused(() => client.collection('c').list());
      expect(e.code, KvStoreException.malformedResponseCode);
      fake.answer(200, '{"entries":[1]}');
      e = await refused(() => client.collection('c').list());
      expect(e.code, KvStoreException.malformedResponseCode);
      fake.answer(200, '{"entries":[{"key":"a"}]}');
      e = await refused(() => client.collection('c').list());
      expect(e.code, KvStoreException.malformedResponseCode);
      fake.answer(200, '{"entries":[{"key":"a","version":1,"valueText":"{"}]}');
      e = await refused(() => client.collection('c').list(values: true));
      expect(e.code, KvStoreException.malformedResponseCode);
    });

    test('the limit bounds are refused locally', () {
      expect(() => client.collection('c').list(limit: 0), throwsArgumentError);
      expect(
        () => client.collection('c').list(limit: 101),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'kv list limit must be between 1 and 100',
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });
  });

  group('incr', () {
    test('PATCH {"incr": n} with an optional ttl', () async {
      fake.answer(200, '{"value":7,"version":3}');
      final result = await client.collection('c').mine.incr('hits', 2, ttl: 60);
      expect(fake.single.method, 'PATCH');
      expect(
        fake.single.url.toString(),
        'https://doc.example/kv/c/u/me/entries/hits?ttl=60',
      );
      expect(fake.single.body, '{"incr":2}');
      expect(fake.single.headers['content-type'], 'application/json');
      expect(result.value, 7);
      expect(result.version, 3);
      fake.answer(200, '{"value":-1,"version":4}');
      await client.collection('c').incr('hits', -8);
      expect(fake.requests.last.body, '{"incr":-8}');
      expect(fake.requests.last.url.hasQuery, isFalse);
    });

    test('409 not_a_number / overflow; a malformed answer', () async {
      for (final reason in <String>['not_a_number', 'overflow']) {
        fake.answer(
          409,
          '{"error":{"code":"conflict","message":"x","details":{"reason":"$reason"}}}',
        );
        final e = await refused(() => client.collection('c').incr('k', 1));
        expect(e.reason, reason);
        expect(e.isConflict, isTrue);
        expect(e.isFull, isFalse);
      }
      fake.answer(200, '{"value":"7"}');
      final e = await refused(() => client.collection('c').incr('k', 1));
      expect(e.code, KvStoreException.malformedResponseCode);
    });
  });

  group('transport', () {
    test('network failures are status 0, code network', () async {
      final ns = client.collection('c');
      fake.fail(
        http.ClientException('boom https://doc.example/kv/c/entries/k'),
      );
      var e = await refused(() => ns.get('k'));
      expect(e.status, 0);
      expect(e.code, KvStoreException.networkCode);
      fake.fail(ArgumentError('Invalid argument: https://doc.example/secret'));
      e = await refused(() => ns.get('k'));
      expect(e.code, KvStoreException.networkCode);
      fake.fail(StateError('closed'));
      e = await refused(() => ns.get('k'));
      expect(e.code, KvStoreException.networkCode);
      expect(
        log.lines.where((l) => l.contains('kv request failed')),
        hasLength(3),
      );
      expect(log.lines.join('\n'), isNot(contains('doc.example')));
    });

    test('the deadline covers the headers and the body', () async {
      final quick = KvStoreClient(
        KvStoreClientOptions(
          baseUrl: Uri.parse('https://doc.example'),
          token: 't',
          client: fake,
          timeout: const Duration(milliseconds: 20),
        ),
      );
      fake.stallHeaders();
      var e = await refused(() => quick.collection('c').get('k'));
      expect(e.code, KvStoreException.networkCode);
      fake.stallBody(200);
      e = await refused(() => quick.collection('c').get('k'));
      expect(e.code, KvStoreException.networkCode);
      await Future<void>.delayed(Duration.zero);
      expect(fake.aborted, <bool>[true, true]);
    });

    test('a body over the cap is refused, declared or streamed', () async {
      final big = FakeHttp();
      final over = KvStoreClient(
        KvStoreClientOptions(
          baseUrl: Uri.parse('https://doc.example'),
          token: 't',
          client: big,
          logger: createFilteredLogger(
            severity: LogSeverity.debug,
            writer: log,
          ),
        ),
      );
      big.answer(200, 'x' * (KvRequester_maxResponseBytes + 1));
      final e = await refused(() => over.collection('c').get('k'));
      expect(e.code, KvStoreException.malformedResponseCode);
      expect(e.status, 200, reason: 'the server did answer');
      expect(log.lines.last, contains('kv request failed'));
      big.answerChunked(200, 'x' * (KvRequester_maxResponseBytes + 1));
      final streamed = await refused(() => over.collection('c').get('k'));
      expect(streamed.code, KvStoreException.malformedResponseCode);
      // Exactly the cap passes, chunked and undeclared; a missing ETag is
      // then the only complaint.
      big.answerChunked(200, '"${'x' * (KvRequester_maxResponseBytes - 2)}"');
      final atCap = await refused(() => over.collection('c').get('k'));
      expect(atCap.code, KvStoreException.malformedResponseCode);
      expect(log.lines.last, contains('"bytes":$KvRequester_maxResponseBytes'));
    });

    test('a drip-fed body is bounded by the one deadline', () async {
      final quick = KvStoreClient(
        KvStoreClientOptions(
          baseUrl: Uri.parse('https://doc.example'),
          token: 't',
          client: fake,
          timeout: const Duration(milliseconds: 60),
        ),
      );
      fake.dripBody(200, const Duration(milliseconds: 10));
      final started = DateTime.now();
      final e = await refused(() => quick.collection('c').get('k'));
      expect(e.code, KvStoreException.networkCode);
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(1000));
      await Future<void>.delayed(Duration.zero);
      expect(fake.aborted, <bool>[
        true,
      ], reason: 'the deadline aborts the request');
    });

    test(
      'unmapped transport exceptions become network, never a message',
      () async {
        fake.fail(
          const FormatException(
            'Invalid HTTP header field value: "Bearer secret"',
          ),
        );
        var e = await refused(() => client.collection('c').get('k'));
        expect(e.code, KvStoreException.networkCode);
        fake.fail(const HttpException('boom', uri: null));
        e = await refused(() => client.collection('c').get('k'));
        expect(e.code, KvStoreException.networkCode);
        expect(log.lines.join('\n'), isNot(contains('secret')));
      },
    );

    test('a token with an illegal character is refused by index', () {
      for (final (token, index) in <(String, int)>[
        ('abc\n', 3),
        ('ab cd', 2),
        ('tökén', 1),
        ('\u0000', 0),
      ]) {
        expect(
          () => KvStoreClient(
            KvStoreClientOptions(
              baseUrl: Uri.parse('https://doc.example'),
              token: token,
              client: fake,
            ),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'kv token has an illegal character at index $index',
            ),
          ),
          reason: token,
        );
      }
      expect(fake.requests, isEmpty);
    });

    test('a base URL with user info, a query or a fragment is refused', () {
      for (final url in <String>[
        'https://u:p@doc.example',
        'https://doc.example/?x=1',
        'https://doc.example/#f',
      ]) {
        expect(
          () => KvStoreClient(
            KvStoreClientOptions(
              baseUrl: Uri.parse(url),
              token: 't',
              client: fake,
            ),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'kv baseUrl must be an absolute http(s) URL with no user info, query or fragment',
            ),
          ),
          reason: url,
        );
      }
    });

    test('a server-chosen code or reason outside the grammar is not kept', () async {
      fake.answer(
        500,
        '{"error":{"code":"$fixtureToken","message":"x","details":{"reason":"Bad Reason"}}}',
      );
      final e = await refused(() => client.collection('c').get('k'));
      expect(e.code, 'http_500');
      expect(e.reason, isNull);
      expect(e.toString(), 'KvStoreException(http_500, 500)');
      fake.answer(500, '{"error":{"code":"${'a' * 65}"}}');
      expect(
        (await refused(() => client.collection('c').get('k'))).code,
        'http_500',
      );
      fake.answer(500, '{"error":{"code":"${'a' * 64}"}}');
      expect(
        (await refused(() => client.collection('c').get('k'))).code,
        'a' * 64,
      );
    });

    test('a request after close is a network failure', () async {
      final owned = KvStoreClient(
        KvStoreClientOptions(
          baseUrl: Uri.parse('https://127.0.0.1:1'),
          token: 't',
          timeout: const Duration(seconds: 1),
        ),
      );
      owned.close();
      final e = await refused(() => owned.collection('c').get('k'));
      expect(e.code, KvStoreException.networkCode);
    });

    test('the token appears in the header and nowhere else', () async {
      fake.answer(200, '{"entries":[]}');
      await client.collection('c').list();
      fake.answer(
        500,
        '{"error":{"code":"internal","message":"$fixtureToken"}}',
      );
      final e = await refused(() => client.collection('c').get('k'));
      // Positive control: the log has the request line; then the negative.
      expect(log.lines, hasLength(2));
      expect(
        log.lines.first,
        '[debug] kv request {"method":"GET","route":"entries","status":200,"bytes":14}',
      );
      expect(log.lines.last, contains('"status":500'));
      expect(log.lines.join('\n'), isNot(contains('secret-token')));
      expect(e.toString(), 'KvStoreException(internal, 500)');
      expect(
        fake.requests.first.headers['authorization'],
        'Bearer $fixtureToken',
      );
      expect(fake.requests.first.url.toString(), isNot(contains('secret')));
    });
  });

  group('parsers', () {
    test('ETag forms and X-KV-Expires-At', () {
      expect(KvStoreException.parseEtagVersion('"3"'), 3);
      expect(KvStoreException.parseEtagVersion('W/"3"'), 3);
      expect(KvStoreException.parseEtagVersion('3'), 3);
      expect(KvStoreException.parseEtagVersion(' 12 '), 12);
      expect(KvStoreException.parseEtagVersion(null), isNull);
      expect(KvStoreException.parseEtagVersion(''), isNull);
      expect(KvStoreException.parseEtagVersion('"abc"'), isNull);
      expect(KvStoreException.parseEtagVersion('"-1"'), isNull);
      expect(KvStoreException.parseEtagVersion('"${'9' * 16}"'), isNull);
      expect(KvStoreException.parseExpiresAt('1700000000'), 1700000000);
      expect(KvStoreException.parseExpiresAt(' 5 '), 5);
      expect(KvStoreException.parseExpiresAt('0'), isNull);
      expect(KvStoreException.parseExpiresAt('-1'), isNull);
      expect(KvStoreException.parseExpiresAt('soon'), isNull);
      expect(KvStoreException.parseExpiresAt(null), isNull);
    });

    test('fromResponse without a body, and the rule constants', () {
      final e = KvStoreException.fromResponse(502, '');
      expect(e.code, 'http_502');
      expect(KvRules.checkTtl(null), isNull);
      expect(KvRules.checkTtl(0), 0);
      expect(KvRules.checkTtl(1), 1);
      expect(KvRules.checkTtl(KvRules.ttlMaxSeconds), KvRules.ttlMaxSeconds);
      expect(KvRules.checkLimit(null), isNull);
      expect(KvRules.checkKey('a' * 128), 'a' * 128);
      expect(KvRules.checkCollectionRef('a' * 64), 'a' * 64);
      expect(KvRules.selfOwner, 'me');
    });
  });
}

// ignore: constant_identifier_names
const int KvRequester_maxResponseBytes = 4 << 20;
