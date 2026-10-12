@Tags(['integration'])
library;

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

void main() {
  test(
    'register and unregister over real HTTP, only own tokens are removed',
    () async {
      final gateway = await FakeGateway.start();
      addTearDown(gateway.shutdown);
      PushClient client(String user) => PushClient(
        PushClientOptions(
          apiBase: gateway.wsUrl.replace(scheme: 'http'),
          channelId: 'push_demo',
          token: user,
          topic: 'configured.topic',
          project: 'demo-project',
        ),
      );
      final a = client('a'), b = client('b');
      addTearDown(a.close);
      addTearDown(b.close);
      await a.register('device-a').timeout(const Duration(seconds: 5));
      await b.register('device-b').timeout(const Duration(seconds: 5));
      expect(gateway.push.tokenCount, 2);
      await a.unregister().timeout(const Duration(seconds: 5));
      expect(gateway.push.contains('a', 'device-a'), false);
      expect(gateway.push.contains('b', 'device-b'), true);
    },
  );
}
