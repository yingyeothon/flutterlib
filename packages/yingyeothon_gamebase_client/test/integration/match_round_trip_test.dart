@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

Future<T> soon<T>(Future<T> future) =>
    future.timeout(const Duration(seconds: 5));
void main() {
  test('two live clients receive the same match and members', () async {
    final server = await FakeMatchServer.start();
    addTearDown(server.shutdown);
    LiveMatchClient client(String user) => LiveMatchClient(
      LiveMatchClientOptions(url: server.wsUrl, channelId: 'ch', token: user),
    );
    final a = client('a'), b = client('b');
    addTearDown(a.close);
    addTearDown(b.close);
    final results = await soon(Future.wait([a.find(), b.find()]));
    expect(results[0].matchId, results[1].matchId);
    expect(results[0].members.map((m) => m.userId), ['a', 'b']);
  });
  test(
    'deferred propose, accept, decline, cooldown and requeue round trip',
    () async {
      var now = 100;
      final server = await FakeMatchServer.start(clock: () => now);
      addTearDown(server.shutdown);
      DeferredMatchClient client(String user) => DeferredMatchClient(
        DeferredMatchClientOptions(
          apiBase: server.httpUrl,
          channelId: 'ch',
          token: user,
        ),
      );
      final a = client('a'), b = client('b');
      addTearDown(a.close);
      addTearDown(b.close);
      await soon(a.submit());
      await soon(b.submit());
      expect((await soon(a.status()))!.state, 'proposed');
      await soon(a.accept());
      expect((await soon(b.accept())).state, 'confirmed');
      expect(
        (await soon(a.status()))!.confirmed!.members.map((m) => m.userId),
        ['a', 'b'],
      );
      await soon(a.cancel());
      await soon(b.cancel());
      await soon(a.submit());
      await soon(b.submit());
      expect((await soon(a.decline())).state, 'declined');
      expect((await soon(b.status()))!.state, 'waiting');
      await expectLater(
        soon(a.submit()),
        throwsA(
          isA<MatchException>().having(
            (e) => e.retryAfter,
            'retry',
            const Duration(seconds: 30),
          ),
        ),
      );
      now += 30;
      await soon(a.submit());
      expect((await soon(a.status()))!.state, 'proposed');
    },
  );
  test('gateway presence marks a connected player', () async {
    final gateway = await FakeGateway.start();
    addTearDown(gateway.shutdown);
    final id = 'a' * 32;
    final lobby = GatewayLobbyClient(
      GatewayLobbyClientOptions(
        url: gateway.wsUrl.toString(),
        channelId: 'ch',
        token: id,
      ),
    );
    addTearDown(lobby.close);
    await soon(lobby.connect());
    final presence = GatewayPresenceClient(
      GatewayPresenceClientOptions(
        baseUrl: gateway.wsUrl.replace(scheme: 'http'),
        channelId: 'ch',
        token: id,
      ),
    );
    addTearDown(presence.close);
    final values = await soon(presence.users([id, 'b' * 32]));
    expect(values.map((v) => v.online), [true, false]);
  });
}
