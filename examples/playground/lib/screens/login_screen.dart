import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';

import '../config.dart';
import '../debug/debug_hooks.dart';
import '../session.dart';
import '../widgets/log_panel.dart';
import 'kv_screen.dart';
import 'lobby_screen.dart';

/// Config, sign-in, and the offline demo.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.session});

  final Session session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _gateway;
  late final TextEditingController _channel;
  late final TextEditingController _authBase;
  late final TextEditingController _authChannel;
  late final TextEditingController _kvBase;
  final TextEditingController _jwt = TextEditingController();
  final TextEditingController _returned = TextEditingController();
  final TextEditingController _redirect = TextEditingController(
    text: 'http://localhost/signin',
  );
  String? _nonce;
  String? _error;
  bool _busy = false;

  Session get session => widget.session;

  @override
  void initState() {
    super.initState();
    final c = session.config;
    _gateway = TextEditingController(text: c.gatewayUrl);
    _channel = TextEditingController(text: c.channelId);
    _authBase = TextEditingController(text: c.authBaseUrl);
    _authChannel = TextEditingController(text: c.authChannelId);
    _kvBase = TextEditingController(text: c.kvBaseUrl);
    if (offlineAutostart || offlineAutostartKv) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _offline();
        if (!mounted || !session.signedIn) return;
        await (offlineAutostartKv ? _openKv() : _enterLobby());
      });
    }
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[
      _gateway,
      _channel,
      _authBase,
      _authChannel,
      _kvBase,
      _jwt,
      _returned,
      _redirect,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  PlaygroundConfig _readConfig() => PlaygroundConfig(
    gatewayUrl: _gateway.text.trim(),
    channelId: _channel.text.trim(),
    authBaseUrl: _authBase.text.trim(),
    authChannelId: _authChannel.text.trim(),
    kvBaseUrl: _kvBase.text.trim(),
  );

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = 'sign-in failed: $e');
    } on Exception catch (e) {
      // Never the token: these are SDK-authored messages.
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteJwt() => _run(() async {
    session.updateConfig(_readConfig());
    final jwt = _jwt.text.trim();
    if (jwt.isEmpty) throw StateError('paste a token first');
    ChannelToken token;
    if (session.config.canSignIn) {
      final verified = await session.authClient().verify(jwt);
      if (verified == null) throw StateError('the token was refused (401)');
      token = verified;
    } else {
      token = ChannelToken(jwt: jwt, userId: '(unverified)', exp: 0);
    }
    session.signIn(token);
    _jwt.clear();
  });

  Future<void> _startBrowser(String provider) => _run(() async {
    session.updateConfig(_readConfig());
    final nonce = AuthClient.newNonce();
    final url = session.authClient().buildStartUrl(
      provider: provider,
      redirect: Uri.parse(_redirect.text.trim()),
      nonce: nonce,
    );
    setState(() => _nonce = nonce);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw StateError('could not open the browser');
    }
  });

  Future<void> _finishBrowser() => _run(() async {
    final nonce = _nonce;
    if (nonce == null) throw StateError('start a sign-in first');
    // tryParse: a FormatException would quote the URL, fragment included.
    final returned = Uri.tryParse(_returned.text.trim());
    _returned.clear(); // the fragment is a credential
    if (returned == null) throw StateError('that is not a URL');
    final token = session.authClient().parseRedirect(
      returned,
      expectedNonce: nonce,
    );
    session.signIn(token);
  });

  Future<void> _offline() => _run(() async {
    await startOfflineDemo(session);
    _gateway.text = session.config.gatewayUrl;
    _channel.text = session.config.channelId;
    _kvBase.text = session.config.kvBaseUrl;
  });

  Future<void> _enterLobby() async {
    await _run(() async {
      session.updateConfig(_readConfig());
      if (!session.config.canConnect) {
        throw StateError('gateway URL and channel id are required');
      }
    });
    if (_error != null || !mounted) return;
    // Outside _run: the lobby visit must not hold this screen busy.
    await Navigator.of(context).pushNamed(LobbyScreen.route);
  }

  Future<void> _openKv() async {
    await _run(() async {
      session.updateConfig(_readConfig());
      if (!session.config.canUseKv) {
        throw StateError('key-value base URL is required');
      }
    });
    if (_error != null || !mounted) return;
    await Navigator.of(context).pushNamed(KvScreen.route);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('yyt playground')),
    body: ListenableBuilder(
      listenable: session,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            'Console values',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          TextField(
            controller: _gateway,
            decoration: const InputDecoration(
              labelText: 'Gateway URL (wss://…)',
            ),
          ),
          TextField(
            controller: _channel,
            decoration: const InputDecoration(labelText: 'Lobby channel id'),
          ),
          TextField(
            controller: _authBase,
            decoration: const InputDecoration(labelText: 'Auth base URL'),
          ),
          TextField(
            controller: _authChannel,
            decoration: const InputDecoration(labelText: 'Auth channel id'),
          ),
          TextField(
            controller: _kvBase,
            decoration: const InputDecoration(
              labelText: 'Key-value store base URL (https://doc…)',
            ),
          ),
          const SizedBox(height: 16),
          Text('Sign in', style: Theme.of(context).textTheme.titleMedium),
          TextField(
            controller: _redirect,
            decoration: const InputDecoration(
              labelText: 'Redirect URL (must be on the auth channel allowlist)',
            ),
          ),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton.tonal(
                onPressed: _busy ? null : () => _startBrowser('github'),
                child: const Text('GitHub'),
              ),
              FilledButton.tonal(
                onPressed: _busy ? null : () => _startBrowser('google'),
                child: const Text('Google'),
              ),
            ],
          ),
          if (_nonce != null) ...<Widget>[
            TextField(
              controller: _returned,
              decoration: const InputDecoration(
                labelText: 'Paste the URL the browser came back to',
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _finishBrowser,
              child: const Text('Finish sign-in'),
            ),
          ],
          TextField(
            controller: _jwt,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Or paste a channel JWT',
            ),
          ),
          TextButton(
            onPressed: _busy ? null : _pasteJwt,
            child: const Text('Use this token'),
          ),
          if (offlineDemoAvailable)
            OutlinedButton.icon(
              key: const Key('offline-demo'),
              onPressed: _busy || session.offlineHandle != null
                  ? null
                  : _offline,
              icon: const Icon(Icons.wifi_off),
              label: const Text('Offline demo'),
            ),
          const SizedBox(height: 16),
          if (session.signedIn)
            Text('Signed in as ${session.token!.userId}')
          else
            const Text('Not signed in'),
          FilledButton(
            key: const Key('enter-lobby'),
            onPressed: _busy || !session.signedIn ? null : _enterLobby,
            child: const Text('Enter the lobby'),
          ),
          FilledButton.tonal(
            key: const Key('open-kv'),
            onPressed: _busy || !session.signedIn ? null : _openKv,
            child: const Text('Key-value store'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          SizedBox(height: 160, child: LogPanel(session: session)),
        ],
      ),
    ),
  );
}
