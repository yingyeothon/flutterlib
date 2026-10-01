import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';
import 'package:yingyeothon_social_client/yingyeothon_social_client.dart';

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

/// Runs [body] and returns the [SocialException] it threw, asserting that
/// its string is the code-and-status template and nothing else.
Future<SocialException> refused(Future<Object?> Function() body) async {
  try {
    await body();
  } on SocialException catch (e) {
    expect(e.toString(), 'SocialException(${e.code}, ${e.status})');
    return e;
  }
  fail('expected a SocialException');
}

// Reply fixtures below are copied from the route handlers in the service's
// `services/state/src/social.ts` (`profileView`, `withProfile`, the
// `/requests` and `/relations` handlers), never from the parser.
const String me32 = '438497d4550fd6d399c259636e3375d7';
const String bob32 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const String carol32 = 'cccccccccccccccccccccccccccccccc';
const String profileBody =
    '{"owner":"$me32","displayName":"Alice","avatar":"heroes/mage","updatedAt":1759276800}';
const String noAvatarBody =
    '{"owner":"$me32","displayName":"Alice","avatar":null,"updatedAt":1759276800}';
const String friendsBody =
    '{"friends":[{"owner":"$bob32","displayName":"Bob","avatar":"heroes/knight","since":1759200000},'
    '{"owner":"$carol32","displayName":null,"avatar":null,"since":1759100000}]}';
const String requestsBody =
    '{"incoming":[{"owner":"$carol32","displayName":"Carol","avatar":null,"since":1759150000}],'
    '"outgoing":[]}';

void main() {
  late FakeHttp fake;
  late CapturingLogWriter log;
  late SocialClient client;

  setUp(() {
    fake = FakeHttp();
    log = CapturingLogWriter();
    client = SocialClient(
      SocialClientOptions(
        baseUrl: Uri.parse('https://doc.example'),
        token: fixtureToken,
        client: fake,
        logger: createFilteredLogger(severity: LogSeverity.debug, writer: log),
      ),
    );
  });

  group('options and grammars', () {
    test('refuse a bad base URL and a bad token', () {
      SocialClientOptions options(Uri url, [String token = 't']) =>
          SocialClientOptions(baseUrl: url, token: token, client: fake);
      expect(
        () => SocialClient(options(Uri.parse('/social'))),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'social baseUrl must be an absolute http(s) URL with no user info, query or fragment',
          ),
        ),
      );
      expect(
        () => SocialClient(options(Uri.parse('https://doc.example'), '')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'social token is required',
          ),
        ),
      );
      expect(
        () => SocialClient(options(Uri.parse('https://doc.example'), 'a b')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'social token has an illegal character at index 1',
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('ids, names and avatars are checked before any request', () async {
      for (final bad in <String>[
        '',
        'me',
        'x' * 32,
        '${'a' * 31}G',
        'guild:red',
      ]) {
        expect(() => client.request(bad), throwsArgumentError, reason: bad);
        expect(() => client.accept(bad), throwsArgumentError, reason: bad);
        expect(() => client.block(bad), throwsArgumentError, reason: bad);
      }
      expect(() => client.server.putProfile('me', 'Red'), throwsArgumentError);
      expect(
        () => client.server.friendsOf('guild:red'),
        throwsArgumentError,
        reason: 'a relation end is always a player',
      );
      for (final bad in <String>[
        '',
        '   ',
        'x' * 33,
        'a\u0000b',
        'a\u200db',
        'a\u2028b',
        'e${'\u0301' * 5}',
      ]) {
        expect(
          () => client.putMyProfile(bad),
          throwsArgumentError,
          reason: bad,
        );
      }
      for (final bad in <String>[
        'https://x/y',
        '/abs',
        'a:b',
        'a/b/c/d/e',
        '',
        'a' * 65,
        '.hidden',
      ]) {
        expect(
          () => client.putMyProfile('ok', avatar: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(() => client.profiles(const <String>[]), throwsArgumentError);
      expect(
        () => client.profiles(
          List.generate(51, (i) => i.toRadixString(16).padLeft(32, '0')),
        ),
        throwsArgumentError,
      );
      expect(
        () => client.profiles(const <String>['nope']),
        throwsArgumentError,
      );
      expect(fake.requests, isEmpty, reason: 'nothing above reached the wire');
      // The edges that pass, each a request.
      fake.answer(201, noAvatarBody);
      await client.putMyProfile('x' * 32);
      fake.answer(201, noAvatarBody);
      await client.putMyProfile('e${'\u0301' * 4}');
      fake.answer(201, noAvatarBody);
      await client.putMyProfile('ok', avatar: 'heroes/knight.png');
      fake.answer(
        201,
        '{"owner":"guild:red","displayName":"Red","avatar":null,"updatedAt":1}',
      );
      await client.server.putProfile('guild:red', 'Red');
      expect(fake.requests, hasLength(4));
    });
  });

  group('routes', () {
    test('my card: GET, PUT whole, DELETE', () async {
      fake.answer(
        404,
        '{"error":{"code":"not_found","message":"profile not found"}}',
      );
      expect(await client.myProfile(), isNull);
      expect(
        fake.requests.single.url.toString(),
        'https://doc.example/social/me/profile',
      );
      expect(
        fake.requests.single.headers['authorization'],
        'Bearer $fixtureToken',
      );

      fake.answer(201, profileBody);
      final created = await client.putMyProfile(
        '  Alice ',
        avatar: 'heroes/mage',
      );
      final put = fake.requests.last;
      expect(put.method, 'PUT');
      expect(put.body, '{"displayName":"Alice","avatar":"heroes/mage"}');
      expect(put.headers['content-type'], 'application/json');
      expect(created.created, isTrue);
      expect(created.profile.owner, me32);
      expect(created.profile.displayName, 'Alice');
      expect(created.profile.avatar, 'heroes/mage');
      expect(created.profile.updatedAt, 1759276800);
      expect(created.profile.raw['owner'], me32);

      fake.answer(200, noAvatarBody);
      final edited = await client.putMyProfile('Alice');
      expect(
        fake.requests.last.body,
        '{"displayName":"Alice"}',
        reason: 'absent clears',
      );
      expect(edited.created, isFalse);
      expect(edited.profile.avatar, isNull);

      fake.answer(200, profileBody);
      final mine = await client.myProfile();
      expect(mine?.displayName, 'Alice');

      fake.answer(204);
      expect(await client.deleteMyProfile(), isTrue);
      expect(fake.requests.last.method, 'DELETE');
      fake.answer(
        404,
        '{"error":{"code":"not_found","message":"profile not found"}}',
      );
      expect(await client.deleteMyProfile(), isFalse);
    });

    test('profiles, friends, requests, blocks', () async {
      fake.answer(200, '{"profiles":[$profileBody]}');
      final cards = await client.profiles(<String>[
        me32,
        bob32,
        me32,
        'guild:red',
      ]);
      expect(
        fake.requests.single.url.toString(),
        'https://doc.example/social/profiles?ids=$me32%2C$bob32%2Cguild%3Ared',
        reason:
            'deduplicated, in order; the query is the one thing Uri escapes',
      );
      expect(cards.single.displayName, 'Alice');

      fake.answer(200, friendsBody);
      final friends = await client.friends();
      expect(
        fake.requests.last.url.toString(),
        'https://doc.example/social/friends',
      );
      expect(friends.map((f) => f.owner), [bob32, carol32]);
      expect(friends.first.displayName, 'Bob');
      expect(friends.first.avatar, 'heroes/knight');
      expect(friends.first.since, 1759200000);
      expect(friends.last.displayName, isNull, reason: 'no card');

      fake.answer(200, requestsBody);
      final requests = await client.requests();
      expect(requests.incoming.single.owner, carol32);
      expect(requests.incoming.single.displayName, 'Carol');
      expect(requests.outgoing, isEmpty);

      fake.answer(200, '{"blocks":[]}');
      expect(await client.blocks(), isEmpty);
      expect(
        fake.requests.last.url.toString(),
        'https://doc.example/social/blocks',
      );
    });

    test('request and the 204 transitions pin their paths', () async {
      fake.answer(201, '{"state":"requested"}');
      final sent = await client.request(bob32);
      expect(fake.requests.single.method, 'POST');
      expect(
        fake.requests.single.url.toString(),
        'https://doc.example/social/requests',
      );
      expect(fake.requests.single.body, '{"to":"$bob32"}');
      expect(sent.state, SocialRelationState.requested);
      expect(sent.created, isTrue);
      fake.answer(200, '{"state":"friends"}');
      final settled = await client.request(bob32);
      expect(settled.state, SocialRelationState.friends);
      expect(settled.created, isFalse);

      final expected = <(Future<void> Function(), String, String)>[
        (() => client.accept(bob32), 'POST', '/social/requests/$bob32/accept'),
        (
          () => client.decline(bob32),
          'POST',
          '/social/requests/$bob32/decline',
        ),
        (() => client.withdraw(bob32), 'DELETE', '/social/requests/$bob32'),
        (() => client.unfriend(bob32), 'DELETE', '/social/friends/$bob32'),
        (() => client.block(bob32), 'PUT', '/social/blocks/$bob32'),
        (() => client.unblock(bob32), 'DELETE', '/social/blocks/$bob32'),
      ];
      for (final (call, method, path) in expected) {
        fake.answer(204);
        await call();
        expect(fake.requests.last.method, method, reason: path);
        expect(fake.requests.last.url.toString(), 'https://doc.example$path');
        expect(fake.requests.last.body, isEmpty);
      }
    });

    test('the server key routes', () async {
      fake.answer(
        200,
        '{"owner":"$me32",$friendsBody'.replaceFirst('{"friends"', '"friends"'),
      );
      final friends = await client.server.friendsOf(me32);
      expect(
        fake.requests.single.url.toString(),
        'https://doc.example/social/u/$me32/friends',
      );
      expect(friends, hasLength(2));

      fake.answer(
        201,
        '{"owner":"guild:red","displayName":"Red","avatar":null,"updatedAt":1}',
      );
      final guild = await client.server.putProfile('guild:red', 'Red');
      expect(
        fake.requests.last.url.toString(),
        // A colon in a path segment is not escaped; the grammar admits it.
        'https://doc.example/social/u/guild:red/profile',
      );
      expect(guild.created, isTrue);
      expect(guild.profile.owner, 'guild:red');

      fake.answer(204);
      expect(await client.server.deleteProfile('guild:red'), isTrue);
      fake.answer(404, '{"error":{"code":"not_found"}}');
      expect(await client.server.deleteProfile(me32), isFalse);

      fake.answer(200, '{"deleted":3}');
      expect(await client.server.deleteRelations(me32), 3);
      expect(
        fake.requests.last.url.toString(),
        'https://doc.example/social/u/$me32/relations',
      );
      fake.answer(200, '{"deleted":2}');
      expect(await client.server.deleteRelations(me32, other: bob32), 2);
      expect(
        fake.requests.last.url.toString(),
        'https://doc.example/social/u/$me32/relations/$bob32',
      );
    });

    test('a base URL with a path keeps it', () async {
      final c = SocialClient(
        SocialClientOptions(
          baseUrl: Uri.parse('https://doc.example/base/'),
          token: fixtureToken,
          client: fake,
        ),
      );
      fake.answer(200, '{"blocks":[]}');
      await c.blocks();
      expect(
        fake.single.url.toString(),
        'https://doc.example/base/social/blocks',
      );
    });
  });

  group('refusals', () {
    test('status, code and reason; never the body', () async {
      Future<SocialException> askBob() => refused(() => client.request(bob32));
      fake.answer(
        409,
        '{"error":{"code":"conflict","message":"set your profile","details":{"reason":"profile_required"}}}',
      );
      final profile = await askBob();
      expect(profile.isConflict, isTrue);
      expect(profile.isProfileRequired, isTrue);
      expect(profile.isFull, isFalse);
      fake.answer(
        409,
        '{"error":{"code":"conflict","details":{"reason":"blocked"}}}',
      );
      expect((await askBob()).isBlocked, isTrue);
      for (final full in <String>[
        'friends_full',
        'peer_friends_full',
        'pending_full',
        'peer_pending_full',
        'blocks_full',
        'channel_full',
      ]) {
        fake.answer(
          409,
          '{"error":{"code":"conflict","details":{"reason":"$full"}}}',
        );
        final e = await askBob();
        expect(e.isFull, isTrue, reason: full);
        expect(e.reason, full);
      }
      fake.answer(
        404,
        '{"error":{"code":"not_found","message":"player not found","details":{"reason":"not_found"}}}',
      );
      final gone = await askBob();
      expect(gone.isNotFound, isTrue);
      expect(gone.reason, 'not_found');
      fake.answer(
        403,
        '{"error":{"code":"forbidden","message":"a player token is required"}}',
      );
      expect((await refused(client.friends)).isForbidden, isTrue);
      fake.answer(401, '');
      final unauthorized = await refused(client.friends);
      expect(unauthorized.isUnauthorized, isTrue);
      expect(unauthorized.code, 'http_401');
      fake.answer(
        400,
        '{"error":{"code":"bad_request","message":"cannot befriend yourself"}}',
      );
      expect((await askBob()).isBadRequest, isTrue);
      // accept/decline/withdraw/unfriend/unblock: a 404 is thrown, not folded.
      fake.answer(404, '{"error":{"code":"not_found"}}');
      expect((await refused(() => client.accept(bob32))).isNotFound, isTrue);
      // A code outside the grammar is dropped, not carried.
      fake.answer(
        503,
        '{"error":{"code":"Oops <html>","details":{"reason":"x y"}}}',
      );
      final odd = await refused(client.friends);
      expect(odd.code, 'http_503');
      expect(odd.reason, isNull);
      expect(log.lines.join('\n'), isNot(contains('<html>')));
    });

    test('a malformed answer, the cap, network failures and the timeout', () async {
      for (final body in <String>['', '[]', 'nope']) {
        fake.answer(200, body);
        final e = await refused(client.friends);
        expect(e.code, SocialException.malformedResponseCode, reason: body);
        expect(e.status, 200);
      }
      fake.answer(200, 'x' * ((1 << 20) + 1));
      expect(
        (await refused(client.friends)).code,
        SocialException.malformedResponseCode,
      );
      fake.answerChunked(200, 'x' * ((1 << 20) + 1));
      expect(
        (await refused(client.friends)).code,
        SocialException.malformedResponseCode,
      );
      fake.fail(http.ClientException('boom https://doc.example/secret'));
      final failed = await refused(client.friends);
      expect(failed.status, 0);
      expect(failed.code, SocialException.networkCode);
      fake.fail(ArgumentError('bad'));
      expect((await refused(client.friends)).code, 'network');
      fake.fail(StateError('closed'));
      expect((await refused(client.friends)).code, 'network');
      final quick = SocialClient(
        SocialClientOptions(
          baseUrl: Uri.parse('https://doc.example'),
          token: fixtureToken,
          client: fake,
          logger: createFilteredLogger(
            severity: LogSeverity.debug,
            writer: log,
          ),
          timeout: const Duration(milliseconds: 20),
        ),
      );
      fake.stallHeaders();
      expect((await refused(quick.friends)).code, 'network');
      fake.stallBody(200);
      expect((await refused(quick.friends)).code, 'network');
      await Future<void>.delayed(Duration.zero);
      expect(fake.aborted.where((a) => a), hasLength(2));
      final all = log.lines.join('\n');
      expect(all, isNot(contains('secret')));
      expect(
        log.lines.where(
          (l) =>
              l ==
              '[warn] social request failed {"method":"GET","route":"friends"}',
        ),
        hasLength(7),
        reason: 'two over-cap bodies and five failures to answer',
      );
    });
  });

  group('logging and lifetime', () {
    test('one debug line per request, never the token, a name or an id', () async {
      fake.answer(201, profileBody);
      await client.putMyProfile('Alice', avatar: 'heroes/mage');
      expect(
        log.lines.single,
        '[debug] social request {"method":"PUT","route":"profile","status":201,"bytes":${profileBody.length}}',
      );
      fake.answer(404, '{"error":{"code":"not_found"}}');
      await refused(() => client.accept(bob32));
      expect(log.lines, hasLength(2));
      expect(log.lines[1], contains('"route":"requests","status":404'));
      // The positive control: the token and the id went out...
      expect(
        fake.requests.first.headers['authorization'],
        contains(fixtureToken),
      );
      expect(fake.requests.last.url.path, contains(bob32));
      // ...and reached no line, nor did the name.
      final all = log.lines.join('\n');
      expect(all, isNot(contains(fixtureToken)));
      expect(all, isNot(contains(bob32)));
      expect(all, isNot(contains('Alice')));
    });

    test(
      'close() closes an owned client once and leaves an injected one',
      () async {
        client.close();
        client.close();
        expect(fake.closed, isFalse);
        final owned = SocialClient(
          SocialClientOptions(
            baseUrl: Uri.parse('https://doc.example'),
            token: fixtureToken,
          ),
        );
        owned.close();
        owned.close();
        expect(
          (await refused(owned.friends)).code,
          SocialException.networkCode,
        );
      },
    );
  });
}
