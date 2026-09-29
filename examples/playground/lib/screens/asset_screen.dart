import 'package:flutter/material.dart';
import 'package:yingyeothon_asset_client/yingyeothon_asset_client.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import '../session.dart';
import '../widgets/close_banner.dart';
import '../widgets/log_panel.dart';

/// One asset bundle: its manifest, a small text file read whole, and a
/// larger file streamed with progress, each verified segment by segment
/// when the bundle is encrypted.
class AssetScreen extends StatefulWidget {
  const AssetScreen({super.key, required this.session});

  static const String route = '/assets';

  final Session session;

  @override
  State<AssetScreen> createState() => _AssetScreenState();
}

class _AssetScreenState extends State<AssetScreen> {
  String? _error;
  bool _busy = false;

  Session get session => widget.session;

  @override
  void initState() {
    super.initState();
    // After the first frame, as the key-value screen does.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _run(() async {
        session.openAssets();
        await session.loadManifest();
      });
    });
  }

  @override
  void dispose() {
    // The demo's only reader, so it goes with the screen; a game keeps one
    // client per bundle for the app's life (the asset client README).
    session.closeAssets(notify: false);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AssetClientException catch (e) {
      // A code and a status: never the key, a URL or a byte of plaintext.
      if (mounted) setState(() => _error = _describe(e));
    } on ArgumentError catch (e) {
      // A base URL the client refused; its message never quotes the URL.
      final message = '${e.message ?? 'invalid argument'}';
      if (mounted) setState(() => _error = message);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _describe(AssetClientException e) => switch (e.code) {
    AssetClientErrorCode.notFound => 'not found: sync the bundle first',
    AssetClientErrorCode.assetCorrupt =>
      'corrupt: a wrong or missing key, a base URL that is not the bundle, '
          'or a tampered file',
    AssetClientErrorCode.badKey =>
      'bad key: YYT_ASSET_KEY is not a canonical yak1. key',
    AssetClientErrorCode.network =>
      'network: ${e.detail ?? 'offline or the connection dropped'}',
    _ => '$e',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Asset bundle')),
    body: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final progress = session.downloadProgress;
        final total = progress?.total;
        final done = session.downloaded;
        return Column(
          children: <Widget>[
            CloseBanner(text: _error),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Text(
                    session.config.assetKey.isEmpty
                        ? 'No key: read as a plain bundle'
                        : 'An encrypted bundle: every 64 KiB segment is '
                              'verified before a byte of it is shown',
                  ),
                  const SizedBox(height: 8),
                  Card(
                    key: const Key('manifest-card'),
                    child: ListTile(
                      title: const Text(Session.manifestPath),
                      subtitle: Text(
                        key: const Key('manifest-state'),
                        session.manifest == null
                            ? 'Not loaded'
                            : Json.encode(session.manifest),
                      ),
                      trailing: TextButton(
                        key: const Key('manifest-reload'),
                        onPressed: _busy
                            ? null
                            : () => _run(session.loadManifest),
                        child: const Text('Reload'),
                      ),
                    ),
                  ),
                  Card(
                    key: const Key('text-card'),
                    child: ListTile(
                      title: const Text(Session.textPath),
                      subtitle: Text(
                        key: const Key('text-state'),
                        session.assetText ?? 'Not read',
                      ),
                      trailing: TextButton(
                        key: const Key('text-read'),
                        onPressed: _busy
                            ? null
                            : () => _run(session.readAssetText),
                        child: const Text('Read'),
                      ),
                    ),
                  ),
                  Card(
                    key: const Key('download-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const Expanded(child: Text(Session.binaryPath)),
                              FilledButton(
                                key: const Key('download-start'),
                                onPressed: _busy
                                    ? null
                                    : () => _run(session.downloadBinary),
                                child: const Text('Download'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: progress == null
                                ? 0
                                : total == null
                                ? null
                                : total == 0
                                ? 1
                                : progress.written / total,
                          ),
                          Text(
                            key: const Key('download-state'),
                            done != null
                                ? 'Downloaded ${done.bytes} bytes'
                                : progress == null
                                ? 'Not started'
                                : '${progress.written} of '
                                      '${total ?? '?'} bytes',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 120, child: LogPanel(session: session)),
          ],
        );
      },
    ),
  );
}
