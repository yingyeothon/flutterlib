import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';

import '../debug/platform_demo_stub.dart'
    if (dart.library.io) '../debug/platform_demo_io.dart';
import '../push/firebase_push_messaging.dart';
import '../session.dart';

/// Match and push verification, with an offline path and optional Android FCM.
class PlatformScreen extends StatefulWidget {
  const PlatformScreen({super.key, required this.session});
  static const route = '/platform';
  final Session session;
  @override
  State<PlatformScreen> createState() => _PlatformScreenState();
}

class _PlatformScreenState extends State<PlatformScreen>
    with WidgetsBindingObserver {
  final List<String> _lines = [];
  bool _busy = false;
  PushClient? _push;
  FirebasePushMessaging? _messaging;
  StreamSubscription<ClassifiedPush>? _received;
  StreamSubscription<PushException>? _refused;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kDebugMode &&
        const bool.fromEnvironment('YYT_OFFLINE_AUTOSTART_PLATFORM')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_run(runPlatformDemo));
      });
    }
  }

  Future<void> _run(Future<List<String>> Function() action) async {
    setState(() => _busy = true);
    try {
      final lines = await action();
      for (final line in lines) {
        widget.session.note(line);
      }
      if (mounted) setState(() => _lines.addAll(lines));
    } catch (_) {
      widget.session.note('Platform check failed');
      if (mounted) {
        setState(
          () => _lines.add(
            'Operation failed; credentials and message bodies are omitted',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<String>> _connectPush() async {
    if (_push != null) await _stopPush();
    final jwt = widget.session.token?.jwt;
    if (jwt == null) return ['Sign in first'];
    final adapter = await FirebasePushMessaging.connect();
    if (adapter == null) {
      return ['Android Firebase configuration is unavailable'];
    }
    if (!mounted) {
      await adapter.close();
      return [];
    }
    final base = Uri.tryParse(
      const String.fromEnvironment('YYT_PUSH_API_BASE'),
    );
    if (base == null || !base.hasScheme) {
      await adapter.close();
      return ['Push kit-config is required'];
    }
    late final PushClient push;
    try {
      push = PushClient(
        PushClientOptions(
          apiBase: base,
          channelId: const String.fromEnvironment('YYT_PUSH_CHANNEL_ID'),
          token: jwt,
          topic: const String.fromEnvironment('YYT_PUSH_TOPIC'),
          project: const String.fromEnvironment('YYT_FIREBASE_PROJECT_ID'),
          messaging: adapter,
        ),
      );
    } catch (_) {
      await adapter.close();
      rethrow;
    }
    _messaging = adapter;
    _push = push;
    _received = push.received.listen((message) {
      if (mounted) {
        setState(
          () => _lines.add(
            message is MatchPush
                ? 'Match wake received; read ticket on resume'
                : 'Push message received',
          ),
        );
      }
    });
    _refused = push.refused.listen((error) {
      if (mounted) {
        setState(
          () => _lines.add('Push refused: ${error.code} (${error.status})'),
        );
      }
    });
    try {
      await push.start();
      if (!mounted) {
        await _stopPush();
        return [];
      }
      if (!adapter.registeredPermission) {
        await _stopPush();
        return ['Push permission or device token is unavailable'];
      }
      return ['Push registered and configured topic subscribed'];
    } catch (_) {
      await _stopPush();
      rethrow;
    }
  }

  Future<List<String>> _stopPush() async {
    try {
      await _push?.unregister();
    } finally {
      await _received?.cancel();
      await _refused?.cancel();
      await _push?.close();
      await _messaging?.close();
      _push = null;
      _messaging = null;
    }
    return ['Push unregistered and topic unsubscribed'];
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _push != null) {
      unawaited(
        _run(() async {
          await _push?.start();
          return ['Push registration refreshed on resume'];
        }),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopPush().catchError((Object _) => <String>[]));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Match and push')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Broadcast topics are public. Match wake messages are hints; the server ticket is authoritative.',
        ),
        if (kDebugMode)
          FilledButton(
            onPressed: _busy ? null : () => _run(runPlatformDemo),
            child: const Text('Run offline match and push'),
          ),
        OutlinedButton(
          onPressed: _busy ? null : () => _run(_connectPush),
          child: const Text('Start Android push'),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _run(_stopPush),
          child: const Text('Unregister push'),
        ),
        for (final line in _lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(line),
          ),
      ],
    ),
  );
}
