import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';

const fixtureJwt = 'eyJ.secret-token.sig';

/// A scripted HTTP client. Records requests; answers from a queue.
final class FakeHttp extends http.BaseClient {
  final List<http.Request> requests = <http.Request>[];
  final List<Object> answers = <Object>[];

  void answer(int status, String body) => answers.add((status, body));
  void fail(Object error) => answers.add(error);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    final next = answers.removeAt(0);
    if (next is (int, String)) {
      return http.StreamedResponse(Stream.value(utf8.encode(next.$2)), next.$1);
    }
    throw next;
  }
}

void main() {
  late FakeHttp fake;
  late AuthClient client;
  setUp(() {
    fake = FakeHttp();
    client = AuthClient(
      baseUrl: Uri.parse('https://auth.example/'),
      channelId: 'auth_0123456789abcdef',
      httpClient: fake,
    );
  });

  test('fetchConfig reads every field and keeps raw', () async {
    // The shape services/auth/src/app.ts sends: callbackUrls by provider,
    // expiresAt in Unix seconds.
    fake.answer(
      200,
      '''
      {"channelId":"auth_0123456789abcdef","issuer":"iss","audience":"aud",
       "tokenTtlSec":86400,"providers":["github","google"],
       "callbackUrls":{"github":"https://auth.example/c/auth_0123456789abcdef/github/callback",
                       "google":"https://auth.example/c/auth_0123456789abcdef/google/callback"},
       "startUrl":"https://auth.example/c/auth_0123456789abcdef/start",
       "redirectAllowlist":["https://game.example/"],"expiresAt":1798675200,"extra":1}''',
    );
    final config = await client.fetchConfig();
    expect(
      fake.requests.single.url.toString(),
      'https://auth.example/c/auth_0123456789abcdef/.well-known/config',
    );
    expect(fake.requests.single.method, 'GET');
    expect(config.channelId, 'auth_0123456789abcdef');
    expect(config.issuer, 'iss');
    expect(config.audience, 'aud');
    expect(config.tokenTtlSec, 86400);
    expect(config.providers, ['github', 'google']);
    expect(config.callbackUrls, {
      'github': 'https://auth.example/c/auth_0123456789abcdef/github/callback',
      'google': 'https://auth.example/c/auth_0123456789abcdef/google/callback',
    });
    expect(config.startUrl, endsWith('/start'));
    expect(config.redirectAllowlist, ['https://game.example/']);
    expect(config.expiresAt, 1798675200); // 2026-12-31T00:00:00Z
    expect(config.raw['extra'], 1);
  });

  test('fetchConfig keeps the no-expiry sentinel as sent', () async {
    // CHANNEL_NO_EXPIRY_SEC in the service's packages/core/src/channel.ts.
    expect(AuthChannelConfig.noExpirySec, 253402300799);
    fake.answer(200, '{"expiresAt":253402300799}');
    final config = await client.fetchConfig();
    expect(config.expiresAt, AuthChannelConfig.noExpirySec);
  });

  test(
    'fetchConfig reads a missing or mistyped field as empty or null',
    () async {
      fake.answer(200, '{}');
      final empty = await client.fetchConfig();
      expect(empty.callbackUrls, isEmpty);
      expect(empty.expiresAt, isNull);

      // The shapes this package once read, and a non-string URL, are dropped.
      fake.answer(
        200,
        '{"callbackUrls":["https://auth.example/cb"],'
        '"expiresAt":"2026-12-31T00:00:00Z"}',
      );
      final legacy = await client.fetchConfig();
      expect(legacy.callbackUrls, isEmpty);
      expect(legacy.expiresAt, isNull);

      fake.answer(
        200,
        '{"callbackUrls":{"github":"https://auth.example/cb","google":1},'
        '"expiresAt":1.5}',
      );
      final mixed = await client.fetchConfig();
      expect(mixed.callbackUrls, {'github': 'https://auth.example/cb'});
      expect(mixed.expiresAt, isNull);
    },
  );

  test('buildStartUrl puts the nonce in the redirect query', () {
    final url = client.buildStartUrl(
      provider: 'github',
      redirect: Uri.parse('https://game.example/signin?keep=1'),
      nonce: 'n0nce',
    );
    expect(url.path, '/c/auth_0123456789abcdef/start');
    expect(url.queryParameters['provider'], 'github');
    expect(
      url.queryParameters['redirect'],
      'https://game.example/signin?keep=1&nonce=n0nce',
    );
  });

  test('parseRedirect returns the token and refuses a bad nonce', () {
    final ok = client.parseRedirect(
      Uri.parse(
        'https://game.example/signin?nonce=abc#token=$fixtureJwt&userId=u1&exp=1700000000',
      ),
      expectedNonce: 'abc',
    );
    expect(ok.jwt, fixtureJwt);
    expect(ok.userId, 'u1');
    expect(ok.exp, 1700000000);
    expect(ok.expiresAt, DateTime.utc(2023, 11, 14, 22, 13, 20));
    expect(ok.isExpired(DateTime.utc(2023, 11, 14, 22, 13, 19)), isFalse);
    expect(ok.isExpired(DateTime.utc(2023, 11, 14, 22, 13, 20)), isTrue);
    expect(ok.toString(), 'ChannelToken(userId: u1, exp: 1700000000)');

    AuthFailureKind kindOf(String uri, String nonce) {
      try {
        client.parseRedirect(Uri.parse(uri), expectedNonce: nonce);
      } on AuthFailure catch (e) {
        expect(e.toString(), isNot(contains('secret-token')));
        return e.kind;
      }
      fail('expected a failure');
    }

    expect(
      kindOf('https://g/x?nonce=abd#token=$fixtureJwt', 'abc'),
      AuthFailureKind.nonceMismatch,
    );
    expect(
      kindOf('https://g/x#token=$fixtureJwt', 'abc'),
      AuthFailureKind.nonceMismatch,
    );
    expect(
      kindOf('https://g/x?nonce=abc', 'abc'),
      AuthFailureKind.missingFragment,
    );
    expect(
      kindOf('https://g/x?nonce=abc#userId=u', 'abc'),
      AuthFailureKind.missingFragment,
    );
    expect(
      kindOf('https://g/x?nonce=ab#token=t', 'abc'),
      AuthFailureKind.nonceMismatch,
      reason: 'a prefix is not equal',
    );
  });

  test('exchange posts exactly one credential and parses the answer', () async {
    fake.answer(200, '{"jwt":"$fixtureJwt","userId":"u1","exp":1700000000}');
    final token = await client.exchange(provider: 'github', accessToken: 'gh');
    final request = fake.requests.single;
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      'https://auth.example/c/auth_0123456789abcdef/token',
    );
    expect(request.headers['content-type'], 'application/json');
    expect(request.body, '{"provider":"github","accessToken":"gh"}');
    expect(token.jwt, fixtureJwt);

    fake.answer(200, '{"jwt":"$fixtureJwt","userId":"u2","exp":1}');
    await client.exchange(provider: 'google', idToken: 'id');
    expect(fake.requests.last.body, '{"provider":"google","idToken":"id"}');

    expect(() => client.exchange(provider: 'github'), throwsArgumentError);
    expect(
      () => client.exchange(provider: 'github', accessToken: 'a', idToken: 'b'),
      throwsArgumentError,
    );
  });

  test('failures carry a kind and a status, never the body', () async {
    fake.answer(400, '{"error":"$fixtureJwt"}');
    await expectLater(
      client.exchange(provider: 'github', accessToken: 'x'),
      throwsA(
        predicate(
          (Object e) =>
              e is AuthFailure &&
              e.kind == AuthFailureKind.httpStatus &&
              e.status == 400 &&
              !e.toString().contains('secret'),
        ),
      ),
    );
    fake.answer(200, 'not json');
    await expectLater(
      client.fetchConfig(),
      throwsA(
        predicate(
          (Object e) => e is AuthFailure && e.kind == AuthFailureKind.notJson,
        ),
      ),
    );
    fake.answer(200, '{"userId":"u"}');
    await expectLater(
      client.exchange(provider: 'github', accessToken: 'x'),
      throwsA(
        predicate(
          (Object e) =>
              e is AuthFailure && e.kind == AuthFailureKind.missingField,
        ),
      ),
    );
    fake.answer(200, '{"jwt":"t","userId":"u"}');
    await expectLater(
      client.exchange(provider: 'github', accessToken: 'x'),
      throwsA(
        predicate(
          (Object e) =>
              e is AuthFailure && e.kind == AuthFailureKind.missingField,
        ),
      ),
    );
    fake.fail(http.ClientException('boom https://auth.example/secret'));
    await expectLater(
      client.fetchConfig(),
      throwsA(
        predicate(
          (Object e) =>
              e is AuthFailure &&
              e.kind == AuthFailureKind.network &&
              !e.toString().contains('auth.example'),
        ),
      ),
    );
    fake.fail(TimeoutException('slow'));
    await expectLater(
      client.fetchConfig(),
      throwsA(
        predicate(
          (Object e) => e is AuthFailure && e.kind == AuthFailureKind.network,
        ),
      ),
    );
  });

  test('verify sends the bearer, maps 401 to null', () async {
    fake.answer(200, '{"userId":"u1","exp":5,"channelId":"c"}');
    final token = await client.verify(fixtureJwt);
    expect(fake.requests.single.headers['authorization'], 'Bearer $fixtureJwt');
    expect(fake.requests.single.url.path, '/c/auth_0123456789abcdef/verify');
    expect(token!.userId, 'u1');
    expect(token.exp, 5);
    expect(token.jwt, fixtureJwt);
    fake.answer(401, '');
    expect(await client.verify(fixtureJwt), isNull);
    fake.answer(500, '');
    await expectLater(
      client.verify(fixtureJwt),
      throwsA(predicate((Object e) => e is AuthFailure && e.status == 500)),
    );
  });

  test('newNonce is URL-safe, unpadded and random', () {
    final a = AuthClient.newNonce();
    final b = AuthClient.newNonce();
    expect(a, isNot(b));
    expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(AuthClient.newNonce(Random(1)), AuthClient.newNonce(Random(1)));
  });

  test('a base URL with a path keeps it', () async {
    final nested = AuthClient(
      baseUrl: Uri.parse('https://h.example/auth'),
      channelId: 'c',
      httpClient: fake,
    );
    fake.answer(200, '{}');
    await nested.fetchConfig();
    expect(
      fake.requests.single.url.toString(),
      'https://h.example/auth/c/c/.well-known/config',
    );
  });
}
