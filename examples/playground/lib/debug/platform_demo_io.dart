import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

/// Exercises both match modes and push without Firebase or credentials.
Future<List<String>> runPlatformDemo() async {
  final server = await FakeMatchServer.start();
  final gateway = await FakeGateway.start();
  final a = LiveMatchClient(
    LiveMatchClientOptions(url: server.wsUrl, channelId: 'live', token: 'a'),
  );
  final b = LiveMatchClient(
    LiveMatchClientOptions(url: server.wsUrl, channelId: 'live', token: 'b'),
  );
  final deferredA = DeferredMatchClient(
    DeferredMatchClientOptions(
      apiBase: server.httpUrl,
      channelId: 'deferred',
      token: 'a',
    ),
  );
  final deferredB = DeferredMatchClient(
    DeferredMatchClientOptions(
      apiBase: server.httpUrl,
      channelId: 'deferred',
      token: 'b',
    ),
  );
  final push = PushClient(
    PushClientOptions(
      apiBase: gateway.wsUrl.replace(scheme: 'http'),
      channelId: 'push_demo',
      token: 'a',
      project: 'demo-project',
      topic: 'configured.topic',
    ),
  );
  try {
    final matches = await Future.wait([a.find(), b.find()])
        .timeout(const Duration(seconds: 5));
    await deferredA.submit();
    await deferredB.submit();
    await deferredA.accept();
    final confirmed = await deferredB.accept();
    await push.register('offline-device');
    final registered = gateway.push.tokenCount;
    final classified = classifyPush(
      PushMessage(
        data: {'channelId': 'deferred', 'matchId': 'm', 'state': 'confirmed'},
      ),
    );
    await push.unregister();
    return [
      'Live match: ${matches.first.members.length} members',
      'Deferred match: ${confirmed.state}',
      'Push: $registered registered, wake ${classified is MatchPush}, ${gateway.push.tokenCount} after sign-out',
    ];
  } finally {
    await a.close();
    await b.close();
    deferredA.close();
    deferredB.close();
    await push.close();
    await server.shutdown();
    await gateway.shutdown();
  }
}
