@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

Future<(int, Object?)> request(
  HttpClient client,
  Uri url,
  String method,
  String token, [
  Object? body,
]) async {
  final req = await client
      .openUrl(method, url)
      .timeout(const Duration(seconds: 5));
  if (token.isNotEmpty) req.headers.set('authorization', 'Bearer $token');
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
  }
  final res = await req.close().timeout(const Duration(seconds: 5));
  final text = await utf8.decoder
      .bind(res)
      .join()
      .timeout(const Duration(seconds: 5));
  return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
}

void main() {
  test(
    'raw deferred HTTP has service methods and caller-specific tickets',
    () async {
      final server = await FakeMatchServer.start();
      addTearDown(server.shutdown);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final ticket = server.httpUrl.resolve('/m/ch/ticket');
      expect((await request(client, ticket, 'GET', '')).$1, 401);
      expect((await request(client, ticket, 'GET', 'a')).$1, 404);
      expect((await request(client, ticket, 'POST', 'a')).$1, 200);
      await request(client, ticket, 'POST', 'b');
      expect(
        (await request(client, ticket, 'GET', 'a')).$2,
        containsPair('state', 'proposed'),
      );
      expect((await request(client, ticket, 'POST', 'a')).$1, 409);
      expect((await request(client, ticket, 'DELETE', 'a')).$1, 204);
      expect((await request(client, ticket, 'GET', 'a')).$1, 404);
      expect(
        (await request(client, ticket, 'GET', 'b')).$2,
        containsPair('state', 'waiting'),
      );
    },
  );
  test(
    'raw token routes isolate callers, channels and device ownership',
    () async {
      final gateway = await FakeGateway.start();
      addTearDown(gateway.shutdown);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final token = gateway.wsUrl
          .replace(scheme: 'http')
          .resolve('/push/push_demo/token');
      expect((await request(client, token, 'PUT', '', {'token': 't'})).$1, 401);
      expect(
        (await request(client, token, 'PUT', 'a', {
          'token': 't',
          'project': 'other',
        })).$1,
        400,
      );
      expect(
        (await request(client, token, 'PUT', 'a', {
          'token': 't',
          'project': 'demo-project',
        })).$1,
        204,
      );
      expect(
        (await request(client, token, 'PUT', 'b', {
          'token': 't',
          'project': 'demo-project',
        })).$1,
        204,
      );
      expect(gateway.push.contains('a', 't'), false);
      expect(gateway.push.tokenCount, 1);
      await request(client, token, 'DELETE', 'a', {'token': 't'});
      expect(gateway.push.contains('b', 't'), true);
      await request(client, token, 'DELETE', 'b', {'token': 't'});
      expect(gateway.push.tokenCount, 0);
      final presence = gateway.wsUrl
          .replace(scheme: 'http')
          .resolve('/presence?channel=ch&users=${'a' * 32}');
      expect((await request(client, presence, 'GET', 'a')).$2, {
        'type': 'presence',
        'users': [
          {'userId': 'a' * 32, 'online': false},
        ],
      });
    },
  );
}
