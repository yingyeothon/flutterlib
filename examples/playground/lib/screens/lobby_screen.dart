import 'package:flutter/material.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import '../debug/debug_hooks.dart';
import '../session.dart';
import '../widgets/chat_list.dart';
import '../widgets/close_banner.dart';
import '../widgets/log_panel.dart';
import '../widgets/party_panel.dart';
import '../widgets/zone_map.dart';
import 'dungeon_screen.dart';

/// Zone map, chat and parties over one lobby client.
class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key, required this.session});

  static const String route = '/lobby';

  final Session session;

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  String? _connectError;
  double _x = 5;
  double _y = 5;
  String _dir = 'n';
  late String _zone;

  Session get session => widget.session;

  @override
  void initState() {
    super.initState();
    _zone = '';
    // After the first frame, so the session's notifications do not land
    // while this screen's route is still building. Not awaited on purpose:
    // the screen renders the connecting state, and the error is shown in
    // place rather than thrown at the framework.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      session
          .connectLobby()
          .then((hello) {
            if (!mounted) return;
            setState(() => _zone = hello.zone);
            session.lobby?.pos(zone: hello.zone, x: _x, y: _y, dir: _dir);
            if (offlineAutostart) seedPeers(session);
          })
          .catchError((Object e) {
            if (mounted) setState(() => _connectError = e.toString());
          });
    });
  }

  @override
  void dispose() {
    // The session outlives the screen; closing here ends the socket.
    session.closeLobby();
    super.dispose();
  }

  void _move(double dx, double dy, String dir) {
    final lobby = session.lobby;
    if (lobby == null || lobby.state != GatewayClientState.connected) return;
    setState(() {
      _x = (_x + dx).clamp(0, 19);
      _y = (_y + dy).clamp(0, 19);
      _dir = dir;
    });
    lobby.pos(zone: _zone, x: _x, y: _y, dir: _dir);
  }

  void _changeZone(String zone) {
    final lobby = session.lobby;
    if (lobby == null || lobby.state != GatewayClientState.connected) return;
    setState(() => _zone = zone);
    lobby.pos(zone: zone, x: _x, y: _y, dir: _dir);
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: session,
          builder: (context, _) => Text(
            'Lobby · ${session.lobby?.state.name ?? 'idle'}'
            '${_zone.isEmpty ? '' : ' · $_zone'}',
          ),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'Dungeon',
            icon: const Icon(Icons.castle),
            onPressed: () =>
                Navigator.of(context).pushNamed(DungeonScreen.route),
          ),
        ],
        bottom: const TabBar(
          tabs: <Widget>[
            Tab(key: Key('tab-zone'), text: 'Zone'),
            Tab(key: Key('tab-chat'), text: 'Chat'),
            Tab(key: Key('tab-party'), text: 'Party'),
          ],
        ),
      ),
      endDrawer: debugHooksAvailable && session.offlineHandle != null
          ? _DebugDrawer(session: session)
          : null,
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final lobby = session.lobby;
          return Column(
            children: <Widget>[
              CloseBanner(text: _connectError ?? session.lastBanner),
              if (session.pendingInvite != null)
                MaterialBanner(
                  content: Text(
                    'Party invite from ${session.pendingInvite!.from}',
                  ),
                  actions: <Widget>[
                    TextButton(
                      onPressed: session.acceptInvite,
                      child: const Text('Accept'),
                    ),
                    TextButton(
                      onPressed: session.declineInvite,
                      child: const Text('Decline'),
                    ),
                  ],
                ),
              Expanded(
                child: TabBarView(
                  children: <Widget>[
                    _ZoneTab(
                      lobby: lobby,
                      x: _x,
                      y: _y,
                      dir: _dir,
                      zone: _zone,
                      onMove: _move,
                      onZone: _changeZone,
                    ),
                    ChatList(session: session),
                    PartyPanel(session: session),
                  ],
                ),
              ),
              SizedBox(height: 120, child: LogPanel(session: session)),
            ],
          );
        },
      ),
    ),
  );
}

class _ZoneTab extends StatelessWidget {
  const _ZoneTab({
    required this.lobby,
    required this.x,
    required this.y,
    required this.dir,
    required this.zone,
    required this.onMove,
    required this.onZone,
  });

  final GatewayLobbyClient? lobby;
  final double x;
  final double y;
  final String dir;
  final String zone;
  final void Function(double dx, double dy, String dir) onMove;
  final void Function(String zone) onZone;

  @override
  Widget build(BuildContext context) {
    final peers = lobby?.peers.all() ?? const <Peer>[];
    final hello = lobby?.hello;
    return Column(
      children: <Widget>[
        Expanded(
          child: ZoneMap(
            key: const Key('zone-map'),
            self: Peer(userId: hello?.userId ?? 'you', x: x, y: y, dir: dir),
            peers: peers,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              IconButton(
                key: const Key('move-left'),
                onPressed: () => onMove(-1, 0, 'w'),
                icon: const Icon(Icons.arrow_left),
              ),
              IconButton(
                key: const Key('move-up'),
                onPressed: () => onMove(0, -1, 'n'),
                icon: const Icon(Icons.arrow_drop_up),
              ),
              IconButton(
                key: const Key('move-down'),
                onPressed: () => onMove(0, 1, 's'),
                icon: const Icon(Icons.arrow_drop_down),
              ),
              IconButton(
                key: const Key('move-right'),
                onPressed: () => onMove(1, 0, 'e'),
                icon: const Icon(Icons.arrow_right),
              ),
              Text('${peers.length} peer(s) in view'),
              if (hello != null)
                SizedBox(
                  width: 160,
                  child: TextField(
                    key: const Key('zone-field'),
                    controller: TextEditingController(
                      text: zone.isEmpty ? hello.zone : zone,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'zone (submit to move)',
                    ),
                    onSubmitted: (z) {
                      if (z.trim().isNotEmpty) onZone(z.trim());
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DebugDrawer extends StatelessWidget {
  const _DebugDrawer({required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) => Drawer(
    child: ListView(
      children: <Widget>[
        const DrawerHeader(child: Text('Debug hooks (kDebugMode)')),
        ListTile(
          key: const Key('seed-peers'),
          leading: const Icon(Icons.group_add),
          title: const Text('Seed 3 peers'),
          onTap: () => seedPeers(session),
        ),
        for (final code in forcedCloseCodes)
          ListTile(
            key: Key('force-close-$code'),
            leading: const Icon(Icons.power_off),
            title: Text('Force close $code'),
            subtitle: Text(
              classifyClose(code, GatewayChannelKind.lobby).reason,
            ),
            onTap: () => forceClose(session, code),
          ),
      ],
    ),
  );
}
