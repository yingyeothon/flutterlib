import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_game_kit/yingyeothon_game_kit.dart';

import '../debug/game_kit_demo_stub.dart'
    if (dart.library.io) '../debug/game_kit_demo_io.dart';
import '../push/firebase_push_messaging.dart';
import '../session.dart';

/// Purpose-shaped API playground, with a full offline scenario walk.
class GameKitScreen extends StatefulWidget {
  const GameKitScreen({super.key, required this.session});
  static const route = '/game-kit';
  final Session session;
  @override
  State<GameKitScreen> createState() => _GameKitScreenState();
}

class _GameKitScreenState extends State<GameKitScreen>
    with WidgetsBindingObserver {
  final _config = TextEditingController(
    text: const String.fromEnvironment('YYT_KIT_CONFIG'),
  );
  final _lines = <String>[];
  GameKit? _kit;
  FirebasePushMessaging? _messaging;
  StreamSubscription<KitError>? _refused;
  StreamSubscription<KitMatchStatus>? _tickets;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kDebugMode &&
        const bool.fromEnvironment('YYT_OFFLINE_AUTOSTART_GAME_KIT')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_run(runGameKitDemo));
      });
    }
  }

  void _note(String line) {
    widget.session.note(line);
    if (mounted) setState(() => _lines.add(line));
  }

  Future<void> _run(Future<List<String>> Function() action) async {
    setState(() => _busy = true);
    try {
      for (final line in await action()) {
        _note(line);
      }
    } on KitError catch (error) {
      _note('Kit refused: ${error.module}/${error.code}');
    } catch (_) {
      _note('Game kit check failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    final kit = _kit;
    _kit = null;
    final messaging = _messaging;
    _messaging = null;
    await _refused?.cancel();
    await _tickets?.cancel();
    await kit?.close();
    await messaging?.close();
  }

  Future<List<String>> _start() async {
    final decoded = Json.tryDecode(_config.text);
    if (decoded is! JsonDecoded || decoded.value is! JsonObject) {
      return ['Paste the public kit-config block'];
    }
    final token = widget.session.token?.jwt;
    if (token == null) return ['Sign in first'];
    await _close();
    final adapter = await FirebasePushMessaging.connect();
    if (!mounted) {
      await adapter?.close();
      return [];
    }
    final kit = GameKit(
      GameKitOptions(
        config: GameKitConfig(decoded.value! as JsonObject),
        pushMessaging: adapter,
        firebaseProject: const String.fromEnvironment(
          'YYT_FIREBASE_PROJECT_ID',
        ),
        matchCallback: const bool.fromEnvironment('YYT_MATCH_CALLBACK'),
      ),
    );
    _kit = kit;
    _messaging = adapter;
    _refused = kit.refused.listen(
      (error) => _note('Kit refused: ${error.module}/${error.code}'),
    );
    _tickets = kit.matchmaking.stateChanged.listen(
      (ticket) => _note('Match ticket: ${ticket.state}'),
    );
    try {
      await kit.session.fromToken(token);
      return ['Kit ready; all modules share the session'];
    } catch (_) {
      await _close();
      rethrow;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        (kIsWeb && state == AppLifecycleState.hidden)) {
      _kit?.setForeground(false);
    }
    if (state == AppLifecycleState.resumed) _kit?.setForeground(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_close().catchError((Object _) {}));
    _config.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Game kit')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'One session for content, save, room, turns, boards, mail, friends, matching and push. Host authority is by agreement.',
        ),
        if (kDebugMode)
          FilledButton(
            onPressed: _busy ? null : () => _run(runGameKitDemo),
            child: const Text('Run offline kit scenarios'),
          ),
        TextField(
          controller: _config,
          minLines: 3,
          maxLines: 7,
          decoration: const InputDecoration(
            labelText: 'Public kit-config JSON',
          ),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _run(_start),
          child: const Text('Start configured kit'),
        ),
        if (_kit != null) ...[
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _kit!.content.get('tuning');
                    return ['Content read'];
                  }),
            child: const Text('Read tuning'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _kit!.save.load('progress');
                    await _kit!.save.store('progress', {'level': 1});
                    return ['Progress saved conditionally'];
                  }),
            child: const Text('Save progress'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _kit!.room.connect();
                    await _kit!.matchmaking.find();
                    return ['Live room formed'];
                  }),
            child: const Text('Find live match'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final ticket = await _kit!.matchmaking.submit();
                    return ['Ticket: ${ticket.state}'];
                  }),
            child: const Text('Submit deferred ticket'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final ticket = await _kit!.matchmaking.accept();
                    return ['Ticket: ${ticket.state}'];
                  }),
            child: const Text('Accept proposal'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _kit!.push.start();
                    return [
                      'Push startup completed; watch refused for device errors',
                    ];
                  }),
            child: const Text('Start Android push'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _kit!.session.signOut();
                    return ['Kit signed out'];
                  }),
            child: const Text('Sign out kit'),
          ),
        ],
        for (final line in _lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(line),
          ),
      ],
    ),
  );
}
