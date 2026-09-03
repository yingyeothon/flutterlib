import 'package:flutter/material.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import '../debug/debug_hooks.dart';
import '../session.dart';
import '../widgets/close_banner.dart';
import '../widgets/log_panel.dart';

/// A `q` session: enter a game id, connect, send frames, watch the end.
class DungeonScreen extends StatefulWidget {
  const DungeonScreen({super.key, required this.session});

  static const String route = '/dungeon';

  final Session session;

  @override
  State<DungeonScreen> createState() => _DungeonScreenState();
}

class _DungeonScreenState extends State<DungeonScreen> {
  late final TextEditingController _channel;
  late final TextEditingController _gameId;
  final TextEditingController _frame = TextEditingController(
    text: '{"type":"move","dx":1}',
  );
  String? _error;

  Session get session => widget.session;

  @override
  void initState() {
    super.initState();
    // A q channel has its own console id; only the offline demo can guess one.
    _channel = TextEditingController(
      text: session.offlineHandle != null ? 'q_demo' : '',
    );
    _gameId = TextEditingController(text: 'g_demo');
    _gameId.addListener(() => setState(() {}));
  }

  /// After a 4001 the run is gone; a retry needs a new gameId.
  bool get _abortedThisGame =>
      session.gameEnded?.code == GatewayCloseCode.aborted &&
      _gameId.text.trim() == _abortedGameId;
  String? _abortedGameId;

  @override
  void dispose() {
    _channel.dispose();
    _gameId.dispose();
    _frame.dispose();
    session.closeGame();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    final gameId = _gameId.text.trim();
    try {
      _abortedGameId = gameId;
      await session.connectGame(_channel.text.trim(), gameId);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _send() {
    final game = session.game;
    if (game == null) return;
    try {
      final frame = Json.decode(_frame.text);
      if (frame is! Map<String, Object?>) {
        throw StateError('frame must be an object');
      }
      game.send(frame);
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Dungeon (q)')),
    body: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final game = session.game;
        final ended = session.gameEnded;
        return Column(
          children: <Widget>[
            CloseBanner(
              text: ended == null
                  ? _error
                  : (ended.code == GatewayCloseCode.aborted
                        ? 'Aborted (${ended.code}): ${ended.reason}'
                        : 'Finished (${ended.code}): ${ended.reason}'),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _channel,
                      decoration: const InputDecoration(
                        labelText: 'q channel id (from the console)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _gameId,
                      decoration: const InputDecoration(labelText: 'gameId'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('q-connect'),
                    onPressed:
                        game?.state == GatewayClientState.connected ||
                            _abortedThisGame
                        ? null
                        : _connect,
                    child: Text(
                      _abortedThisGame
                          ? 'new gameId needed'
                          : (game == null ? 'Connect' : game.state.name),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _frame,
                      decoration: const InputDecoration(
                        labelText: 'frame (JSON)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    key: const Key('q-send'),
                    onPressed: game?.state == GatewayClientState.connected
                        ? _send
                        : null,
                    child: const Text('Send'),
                  ),
                  if (debugHooksAvailable &&
                      session.offlineHandle != null) ...<Widget>[
                    const SizedBox(width: 8),
                    TextButton(
                      key: const Key('q-abort'),
                      onPressed: game == null
                          ? null
                          : () => endGame(session, _gameId.text.trim(), 4001),
                      child: const Text('Abort (4001)'),
                    ),
                    TextButton(
                      key: const Key('q-finish'),
                      onPressed: game == null
                          ? null
                          : () => endGame(session, _gameId.text.trim(), 1000),
                      child: const Text('Finish (1000)'),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                key: const Key('q-frames'),
                itemCount: session.gameFrames.length,
                itemBuilder: (context, i) => ListTile(
                  dense: true,
                  title: Text(Json.encode(session.gameFrames[i])),
                ),
              ),
            ),
            SizedBox(height: 120, child: LogPanel(session: session)),
          ],
        );
      },
    ),
  );
}
