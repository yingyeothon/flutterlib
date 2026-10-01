import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';

import '../config.dart';
import '../debug/debug_hooks.dart';
import '../session.dart';
import '../widgets/log_panel.dart';
import 'asset_screen.dart';
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
  late final TextEditingController _assetBase;
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
    _assetBase = TextEditingController(text: c.assetBaseUrl);
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
      _assetBase,
      _jwt,
      _returned,
      _redirect,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // copyWith: the asset key has no field and must survive an edit.
  PlaygroundConfig _readConfig() => session.config.copyWith(
    gatewayUrl: _gateway.text.trim(),
    channelId: _channel.text.trim(),
    authBaseUrl: _authBase.text.trim(),
    authChannelId: _authChannel.text.trim(),
    kvBaseUrl: _kvBase.text.trim(),
    assetBaseUrl: _assetBase.text.trim(),
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
    } on StateError catch (e) {
      // An Error, not an Exception: this screen's own "fill this in" checks.
      if (mounted) setState(() => _error = e.toString());
    } on ArgumentError catch (e) {
      // A library's local refusal of an edited value (a base URL that is not
      // a bare http(s) URL); its message names the rule, never the input.
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
    _assetBase.text = session.config.assetBaseUrl;
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

  Future<void> _serverTime() => _run(() async {
    session.updateConfig(_readConfig());
    await session.fetchServerTime();
  });

  Future<void> _openAssets() async {
    await _run(() async {
      session.updateConfig(_readConfig());
      if (!session.config.canUseAssets) {
        throw StateError('asset base URL is required');
      }
    });
    if (_error != null || !mounted) return;
    await Navigator.of(context).pushNamed(AssetScreen.route);
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
          TextField(
            key: const Key('asset-base'),
            controller: _assetBase,
            decoration: InputDecoration(
              labelText: 'Asset bundle base URL (https://d…/assets/ab_…/)',
              // The key comes from --dart-define=YYT_ASSET_KEY only.
              helperText: session.config.assetKey.isEmpty
                  ? 'no YYT_ASSET_KEY: read as plain'
                  : 'key from YYT_ASSET_KEY: read as encrypted',
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
          FilledButton.tonal(
            key: const Key('open-assets'),
            onPressed: _busy ? null : _openAssets,
            child: const Text('Asset bundle'),
          ),
          // No sign-in: the one state route that belongs to nobody.
          FilledButton.tonal(
            key: const Key('server-time'),
            onPressed: _busy ? null : _serverTime,
            child: const Text('Server time'),
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
