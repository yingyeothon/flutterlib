// Drives the friends screen against the in-process fake gateway's /social
// routes over the real http client. `tester.runAsync` lets real sockets
// progress inside a widget test; `pumpUntil` polls the tree.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yyt_playground/config.dart';
import 'package:yyt_playground/main.dart';
import 'package:yyt_playground/screens/social_screen.dart';
import 'package:yyt_playground/session.dart';

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String Function()? describe,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met${describe == null ? '' : ': ${describe()}'}');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

const String seed1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String seed2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// A real-time tick, so a `_run` whose action just finished reaches its
/// `finally` (the button is disabled while busy), then a settled frame.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  late FakeGateway gw;
  late Session session;

  setUp(() async {
    // flutter_test answers every HttpClient with an empty 400; the client
    // talks to the fake over a real socket (this file is its own isolate).
    HttpOverrides.global = null;
    gw = await FakeGateway.start(
      options: const FakeGatewayOptions(
        socialProfiles: <FakeSocialProfile>[
          FakeSocialProfile(owner: seed1, displayName: 'Seed One'),
          // Seeded past the write filter: a name the screen must not show.
          FakeSocialProfile(owner: seed2, displayName: 'Bad\u034fName'),
        ],
      ),
    );
    session = Session(
      config: PlaygroundConfig(
        gatewayUrl: '',
        channelId: '',
        authBaseUrl: '',
        authChannelId: '',
        kvBaseUrl: gw.kvUrl.toString(),
      ),
    );
    session.token = const ChannelToken(jwt: 'you', userId: 'you', exp: 0);
  });

  tearDown(() async {
    session.dispose();
    await gw.shutdown();
  });

  int loads() => session.log.where((l) => l.text.startsWith('social: ')).length;

  /// How many times `loadSocial` has logged exactly [line].
  int seen(String line) => session.log.where((l) => l.text == line).length;

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(PlaygroundApp(session: session));
    });
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .pushNamed(SocialScreen.route);
    await pumpUntil(tester, () => loads() >= 1);
    await settle(tester);
  }

  testWidgets('a card, a request the peer accepts, then a friend', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('No card yet'), findsOneWidget);
    expect(find.text('0 waiting for me, 0 sent'), findsOneWidget);
    expect(find.text('0 friend(s)'), findsOneWidget);

    // Asking before a card is the server's 409, shown in place.
    await tester.enterText(find.byKey(const Key('request-to')), seed1);
    await tester.tap(find.byKey(const Key('request-send')));
    await pumpUntil(
      tester,
      () => find.textContaining('set your card first').evaluate().isNotEmpty,
    );
    expect(gw.social.relation('you', seed1), isNull);

    await tester.tap(find.byKey(const Key('card-save')));
    await pumpUntil(
      tester,
      () => seen('social: a card, 0 friend(s), 0 in, 0 out') == 1,
    );
    await settle(tester);
    expect(find.text('Card: Player (heroes/mage)'), findsOneWidget);
    expect(gw.social.displayNameOf('you'), 'Player');

    final ask = find.byKey(const Key('request-send'));
    await pumpUntil(
      tester,
      () => tester.widget<FilledButton>(ask).onPressed != null,
      describe: () => 'still busy after the card save',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('request-to')))
          .controller!
          .text,
      seed1,
    );
    await tester.ensureVisible(ask);
    await tester.tap(ask);
    await pumpUntil(
      tester,
      () => seen('social: a card, 0 friend(s), 0 in, 1 out') == 1,
      describe: () => session.log.map((l) => l.text).join(' | '),
    );
    await settle(tester);
    expect(find.text('0 waiting for me, 1 sent'), findsOneWidget);
    expect(gw.social.relation('you', seed1), 'requested');

    // The peer accepts (through the fake's raw route), then a refresh.
    await tester.runAsync(() async {
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          gw.kvUrl.resolve('/social/requests/you/accept'),
        );
        request.headers.set('authorization', 'Bearer $seed1');
        await (await request.close()).drain<void>();
      } finally {
        client.close();
      }
    });
    await tester.tap(find.byKey(const Key('social-refresh')));
    await pumpUntil(
      tester,
      () => seen('social: a card, 1 friend(s), 0 in, 0 out') == 1,
    );
    await settle(tester);
    expect(find.text('1 friend(s)'), findsOneWidget);
    expect(find.text('Seed One'), findsOneWidget);
    expect(find.text('0 waiting for me, 0 sent'), findsOneWidget);

    await tester.tap(find.byKey(Key('unfriend-$seed1')));
    await pumpUntil(
      tester,
      () => seen('social: a card, 0 friend(s), 0 in, 0 out') == 2,
    );
    expect(gw.social.relation(seed1, 'you'), isNull);
    // The log names counts, never a name or a token; the 201 on a route
    // that needs the bearer is the positive control that it went out.
    final log = session.log.map((l) => l.text).join('\n');
    expect(log, contains('"route":"profile","status":201'));
    expect(log, contains('social: a card, 1 friend(s), 0 in, 0 out'));
    expect(log, isNot(contains('Bearer')));
    expect(log, isNot(contains('Seed One')));
  });

  testWidgets('an incoming request is accepted from the inbox', (tester) async {
    await tester.runAsync(() async {
      // seed-1 asks `you`, who holds a card already.
      final client = HttpClient();
      try {
        var request = await client.putUrl(
          gw.kvUrl.resolve('/social/me/profile'),
        );
        request.headers.set('authorization', 'Bearer you');
        request.headers.contentType = ContentType.json;
        request.write('{"displayName":"You"}');
        await (await request.close()).drain<void>();
        for (final who in <String>[seed1, seed2]) {
          request = await client.postUrl(gw.kvUrl.resolve('/social/requests'));
          request.headers.set('authorization', 'Bearer $who');
          request.headers.contentType = ContentType.json;
          request.write('{"to":"you"}');
          await (await request.close()).drain<void>();
        }
      } finally {
        client.close();
      }
    });
    await open(tester);
    expect(find.text('2 waiting for me, 0 sent'), findsOneWidget);
    expect(find.text('Seed One'), findsOneWidget);
    // The name with a combining grapheme joiner fails the label check: the
    // owner id stands in for it, twice (title and subtitle).
    expect(find.textContaining('Bad'), findsNothing);
    expect(find.text(seed2), findsNWidgets(2));
    await tester.tap(find.byKey(Key('accept-$seed1')));
    await pumpUntil(
      tester,
      () => seen('social: a card, 1 friend(s), 1 in, 0 out') == 1,
    );
    await settle(tester);
    expect(find.text('1 friend(s)'), findsOneWidget);
    expect(gw.social.relation('you', seed1), 'friends');
  });

  testWidgets('a bad display name is refused in place; Back closes quietly', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('card-name')), '');
    await tester.tap(find.byKey(const Key('card-save')));
    await settle(tester);
    expect(find.textContaining('displayName must be 1 to 32'), findsOneWidget);
    expect(gw.social.displayNameOf('you'), isNull);
    expect(session.social, isNotNull);
    await tester.pageBack();
    await settle(tester);
    expect(session.social, isNull);
    expect(tester.takeException(), isNull);
  });
}
