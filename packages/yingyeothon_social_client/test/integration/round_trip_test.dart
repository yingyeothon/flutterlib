// The client over a real `package:http` client against a loopback server:
// the fake gateway's `/social/*` routes, and, when `YYT_KV_BASE_URL`,
// `YYT_KV_TOKEN` and `YYT_SOCIAL_FRIEND` (a second player's id on the same
// auth channel, holding a card) are set, the dev state stack too. No value
// is ever printed.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_social_client/yingyeothon_social_client.dart';

Future<T> soon<T>(Future<T> f) => f.timeout(const Duration(seconds: 10));

/// The guide's case against any server that follows the contract: set my
/// card, ask [friend] (who holds a card), see the request in my outbox and
/// the friend's card in `profiles`, then withdraw.
Future<void> walk(SocialClient client, String friend) async {
  final card = await soon(
    client.putMyProfile('Playground', avatar: 'heroes/mage'),
  );
  expect(card.profile.displayName, 'Playground');
  expect((await soon(client.myProfile()))?.avatar, 'heroes/mage');

  final sent = await soon(client.request(friend));
  expect(
    sent.state,
    isIn(<String>[SocialRelationState.requested, SocialRelationState.friends]),
  );
  if (sent.state == SocialRelationState.requested) {
    final requests = await soon(client.requests());
    expect(requests.outgoing.map((r) => r.owner), contains(friend));
    await soon(client.withdraw(friend));
    expect(
      (await soon(client.requests())).outgoing.map((r) => r.owner),
      isNot(contains(friend)),
    );
  }
  final cards = await soon(client.profiles(<String>[friend]));
  expect(cards.map((c) => c.owner), contains(friend));
  expect(await soon(client.deleteMyProfile()), isTrue);
  expect(await soon(client.myProfile()), isNull);
}

void main() {
  test('round trip against the fake gateway', () async {
    const bob = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final gw = await FakeGateway.start(
      options: const FakeGatewayOptions(
        socialProfiles: <FakeSocialProfile>[
          FakeSocialProfile(owner: bob, displayName: 'Bob'),
        ],
      ),
    );
    final client = SocialClient(
      SocialClientOptions(baseUrl: gw.kvUrl, token: 'alice'),
    );
    try {
      await walk(client, bob);
      expect(gw.social.displayNameOf('alice'), isNull);
      // The server key: a guild card, then the moderation delete.
      final server = SocialClient(
        SocialClientOptions(
          baseUrl: gw.kvUrl,
          token: 'yds.auth_0123456789abcdef.k',
        ),
      );
      try {
        final guild = await soon(server.server.putProfile('guild:red', 'Red'));
        expect(guild.created, isTrue);
        expect(await soon(server.server.friendsOf(bob)), isEmpty);
        expect(await soon(server.server.deleteRelations(bob)), 0);
        expect(await soon(server.server.deleteProfile('guild:red')), isTrue);
      } finally {
        server.close();
      }
    } finally {
      client.close();
      await gw.shutdown();
    }
  });

  test('round trip against dev', () async {
    final baseUrl = Platform.environment['YYT_KV_BASE_URL'];
    final token = Platform.environment['YYT_KV_TOKEN'];
    final friend = Platform.environment['YYT_SOCIAL_FRIEND'];
    if (baseUrl == null || token == null || friend == null) {
      markTestSkipped(
        'YYT_KV_BASE_URL, YYT_KV_TOKEN, YYT_SOCIAL_FRIEND not set',
      );
      return;
    }
    // tryParse: a FormatException would quote the operator's URL.
    final base = Uri.tryParse(baseUrl);
    if (base == null) fail('YYT_KV_BASE_URL is not a URL');
    final client = SocialClient(
      SocialClientOptions(baseUrl: base, token: token),
    );
    try {
      await walk(client, friend);
    } finally {
      client.close();
    }
  });
}
