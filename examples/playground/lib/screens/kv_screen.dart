import 'package:flutter/material.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_kvstore_client/yingyeothon_kvstore_client.dart';

import '../debug/debug_hooks.dart';
import '../session.dart';
import '../widgets/close_banner.dart';
import '../widgets/log_panel.dart';

/// The two cases the guide shows: a read-only announcements board and the
/// player's own settings record.
class KvScreen extends StatefulWidget {
  const KvScreen({super.key, required this.session});

  static const String route = '/kv';

  final Session session;

  @override
  State<KvScreen> createState() => _KvScreenState();
}

class _KvScreenState extends State<KvScreen> {
  final TextEditingController _volume = TextEditingController(text: '0.5');
  String? _error;
  bool _busy = false;

  Session get session => widget.session;

  @override
  void initState() {
    super.initState();
    // After the first frame, so the session's notifications do not land
    // while this screen's route is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _run(() async {
        session.openKv();
        await session.loadAnnouncements();
        await session.loadSettings();
        if (offlineAutostartKv) await _save();
      });
    });
  }

  @override
  void dispose() {
    _volume.dispose();
    session.closeKv();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on KvStoreException catch (e) {
      // The code and the status: never a key, a value or the token.
      if (mounted) setState(() => _error = _describe(e));
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } on StateError catch (e) {
      // An Error, not an Exception: the screen's own "do this first" checks.
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _describe(KvStoreException e) {
    if (e.isUnauthorized) return 'refused (401): sign in again';
    if (e.isForbidden) return 'forbidden (403): the scope refuses this token';
    if (e.isNotFound) return 'not found (404): create the collection first';
    if (e.isFull) return 'full (409 ${e.reason})';
    if (e.status == 0) return 'network: ${e.code}';
    return '$e';
  }

  Future<void> _save() => _run(() async {
    final volume = double.tryParse(_volume.text.trim());
    if (volume == null) throw StateError('volume must be a number');
    await session.saveSettings(<String, Object?>{'volume': volume});
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const _KvAppBar(),
    body: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final settings = session.settings;
        final value = settings?.value;
        return Column(
          children: <Widget>[
            CloseBanner(text: _error),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Card(
                    key: const Key('announcements-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  'Announcements',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              TextButton(
                                key: const Key('announcements-refresh'),
                                onPressed: _busy
                                    ? null
                                    : () => _run(session.loadAnnouncements),
                                child: const Text('Refresh'),
                              ),
                            ],
                          ),
                          const Text(
                            'collection announcements, readScope project, '
                            'writeScope team: players read, the team writes',
                          ),
                          const SizedBox(height: 8),
                          if (session.announcements.isEmpty)
                            const Text('No announcements')
                          else
                            for (final entry in session.announcements)
                              ListTile(
                                dense: true,
                                title: Text(_titleOf(entry)),
                                subtitle: Text(_bodyOf(entry)),
                                trailing: Text(
                                  '${entry.key} · v${entry.version}',
                                ),
                              ),
                        ],
                      ),
                    ),
                  ),
                  Card(
                    key: const Key('settings-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'My settings',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            'collection profile, readScope user, writeScope '
                            'user: /u/me, only this player sees it',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            key: const Key('settings-state'),
                            settings == null
                                ? (session.settingsAbsent
                                      ? 'No settings stored yet'
                                      : 'Not loaded')
                                : 'Stored: ${Json.encode(value)} '
                                      '(version ${settings.version})',
                          ),
                          Row(
                            children: <Widget>[
                              SizedBox(
                                width: 160,
                                child: TextField(
                                  key: const Key('settings-volume'),
                                  controller: _volume,
                                  decoration: const InputDecoration(
                                    labelText: 'volume',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const Key('settings-save'),
                                onPressed: _busy ? null : _save,
                                child: const Text('Save'),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                key: const Key('settings-load'),
                                onPressed: _busy
                                    ? null
                                    : () => _run(session.loadSettings),
                                child: const Text('Load'),
                              ),
                            ],
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

  static String _titleOf(KvListEntry entry) {
    final value = entry.value;
    if (value is Map<String, Object?>) {
      final title = value.getString('title');
      if (title != null) return title;
    }
    return entry.hasValue ? Json.encode(value) : '(no value)';
  }

  static String _bodyOf(KvListEntry entry) {
    final value = entry.value;
    if (value is Map<String, Object?>) return value.getString('body') ?? '';
    return '';
  }
}

class _KvAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _KvAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) =>
      AppBar(title: const Text('Key-value store'));
}
