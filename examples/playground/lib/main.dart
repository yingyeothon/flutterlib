import 'package:flutter/material.dart';
import 'package:yingyeothon_tracer_flutter/yingyeothon_tracer_flutter.dart';

import 'screens/asset_screen.dart';
import 'screens/dungeon_screen.dart';
import 'screens/game_kit_screen.dart';
import 'screens/kv_screen.dart';
import 'screens/leaderboard_screen.dart';
import 'screens/lobby_screen.dart';
import 'screens/login_screen.dart';
import 'screens/platform_screen.dart';
import 'screens/social_screen.dart';
import 'screens/tracer_screen.dart';
import 'session.dart';

void main() {
  // Off unless the build passed --dart-define=TRACER_DSN=…; GIT_SHA, when
  // given, becomes the git_sha tag and the dist. Off in a release build. The
  // release is the package's own <packageName>@<version>+<buildNumber>.
  TracerFlutter.initUi();
  runApp(PlaygroundApp(session: Session()));
}

final TracerNavigatorObserver _navigation = TracerNavigatorObserver();

/// The app: one [Session], its screens, wrapped for tracer screenshots.
class PlaygroundApp extends StatelessWidget {
  const PlaygroundApp({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) => TracerScreenshot(
    child: MaterialApp(
      title: 'yyt playground',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      navigatorObservers: [_navigation],
      routes: <String, WidgetBuilder>{
        '/': (_) => LoginScreen(session: session),
        LobbyScreen.route: (_) => LobbyScreen(session: session),
        DungeonScreen.route: (_) => DungeonScreen(session: session),
        KvScreen.route: (_) => KvScreen(session: session),
        LeaderboardScreen.route: (_) => LeaderboardScreen(session: session),
        SocialScreen.route: (_) => SocialScreen(session: session),
        GameKitScreen.route: (_) => GameKitScreen(session: session),
        PlatformScreen.route: (_) => PlatformScreen(session: session),
        AssetScreen.route: (_) => AssetScreen(session: session),
        TracerScreen.route: (_) => TracerScreen(session: session),
      },
    ),
  );
}
