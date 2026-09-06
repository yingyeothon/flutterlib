import 'package:flutter/material.dart';

import 'screens/dungeon_screen.dart';
import 'screens/kv_screen.dart';
import 'screens/lobby_screen.dart';
import 'screens/login_screen.dart';
import 'session.dart';

void main() => runApp(PlaygroundApp(session: Session()));

/// The app: one [Session], four screens.
class PlaygroundApp extends StatelessWidget {
  const PlaygroundApp({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'yyt playground',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    routes: <String, WidgetBuilder>{
      '/': (_) => LoginScreen(session: session),
      LobbyScreen.route: (_) => LobbyScreen(session: session),
      DungeonScreen.route: (_) => DungeonScreen(session: session),
      KvScreen.route: (_) => KvScreen(session: session),
    },
  );
}
