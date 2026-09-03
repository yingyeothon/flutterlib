// Everything here is reachable only when `kDebugMode` is true. A release
// build compiles the file but every entry point returns early, and the UI
// that calls it is not built.
import 'package:flutter/foundation.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';

import '../session.dart';
import 'offline_stub.dart' if (dart.library.io) 'offline_io.dart';

/// Whether the debug affordances exist in this build.
bool get debugHooksAvailable => kDebugMode;

/// Whether the offline demo can run on this platform.
bool get offlineDemoAvailable => kDebugMode && !kIsWeb;

/// `--dart-define=YYT_OFFLINE_AUTOSTART=true` (debug builds only): start the
/// offline demo, enter the lobby and seed peers without touching the UI, so
/// a screenshot or a smoke run needs no input tooling.
bool get offlineAutostart =>
    offlineDemoAvailable &&
    const bool.fromEnvironment('YYT_OFFLINE_AUTOSTART', defaultValue: false);

/// The close codes the debug drawer offers.
const List<int> forcedCloseCodes = <int>[4000, 4002, 4004, 4005, 1001];

/// Starts the fake gateway, points the session at it and signs in as
/// `you` (the fake takes the token text as the user id).
Future<void> startOfflineDemo(Session session) async {
  if (!offlineDemoAvailable) return;
  final demo = await OfflineDemo.start();
  session.offlineHandle = demo;
  session.updateConfig(
    session.config.copyWith(
      gatewayUrl: demo.gatewayUrl,
      channelId: 'lobby_demo',
    ),
  );
  session.signIn(
    ChannelToken(
      jwt: 'you',
      userId: 'you',
      exp:
          DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/
          1000,
    ),
  );
  session.note('offline demo: fake gateway at ${demo.gatewayUrl}');
}

OfflineDemo? _demo(Session session) {
  if (!kDebugMode) return null;
  final handle = session.offlineHandle;
  return handle is OfflineDemo ? handle : null;
}

/// Seeds three wandering peers into the session's current zone.
Future<void> seedPeers(Session session) async {
  final demo = _demo(session);
  final zone = session.lobby?.peers.zone ?? session.lobby?.hello?.zone;
  if (demo == null || zone == null) return;
  await demo.seedPeers(zone);
  session.note('seeded 3 peers into $zone');
}

/// Asks the fake to close the lobby socket with [code].
Future<void> forceClose(Session session, int code) async {
  final demo = _demo(session);
  final userId = session.token?.userId;
  if (demo == null || userId == null) return;
  session.note('forcing close $code');
  await demo.closeUser(userId, code);
}

/// Asks the fake to close the `q` socket with [code] (4001 aborts, 1000
/// finishes).
Future<void> endGame(Session session, String gameId, int code) async {
  final demo = _demo(session);
  final userId = session.token?.userId;
  if (demo == null || userId == null) return;
  session.note('ending game $gameId with $code');
  await demo.closeGame(userId, gameId, code);
}

/// Stops the fake gateway.
Future<void> stopOfflineDemo(Session session) async {
  final demo = _demo(session);
  if (demo == null) return;
  session.offlineHandle = null;
  await demo.stop();
}
