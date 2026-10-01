import 'package:flutter/material.dart';
import 'package:yingyeothon_social_client/yingyeothon_social_client.dart';

import '../debug/debug_hooks.dart';
import '../debug/offline_io.dart' show demoFriendId;
import '../map_layout.dart';
import '../session.dart';
import '../widgets/close_banner.dart';
import '../widgets/log_panel.dart';

/// The guide's case: my card, a friend request to a player id, the inbox
/// to accept from, and the friends list with cards folded in.
class SocialScreen extends StatefulWidget {
  const SocialScreen({super.key, required this.session});

  static const String route = '/social';

  final Session session;

  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen> {
  final TextEditingController _name = TextEditingController(text: 'Player');
  final TextEditingController _avatar = TextEditingController(
    text: 'heroes/mage',
  );
  final TextEditingController _to = TextEditingController();
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
        session.openSocial();
        await session.loadSocial();
        if (offlineAutostartSocial) {
          await session.putMyCard('Player', avatar: 'heroes/mage');
          await session.requestFriend(demoFriendId);
        }
      });
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _avatar.dispose();
    _to.dispose();
    // notify: false — the tree is locked during dispose (rules/flutter.md).
    session.closeSocial(notify: false);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on SocialException catch (e) {
      // The code and the status: never a name, an id or the token.
      if (mounted) setState(() => _error = _describe(e));
    } on Exception catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } on StateError catch (e) {
      // An Error, not an Exception: the screen's own "do this first" checks.
      if (mounted) setState(() => _error = e.toString());
    } on ArgumentError catch (e) {
      // A library's local refusal; its message names the rule, never the
      // input.
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A display name is another player's text: shown only when it passes the
  /// map's label check, else the owner id stands in (rules/security.md).
  static String _nameOf(String? name, String owner) =>
      name != null && MapLayout.isLabel(name, SocialRules.displayNameMax)
      ? name
      : owner;

  static String _describe(SocialException e) {
    if (e.isUnauthorized) return 'refused (401): sign in again';
    if (e.isForbidden) return 'forbidden (403): a player token is required';
    if (e.isNotFound) return 'not found (404): no card, or they blocked you';
    if (e.isProfileRequired) return 'set your card first (409)';
    if (e.isBlocked) return 'you blocked them (409)';
    if (e.isFull) return 'full (409 ${e.reason})';
    if (e.status == 0) return 'network: ${e.code}';
    return '$e';
  }

  Future<void> _saveCard() => _run(() async {
    final avatar = _avatar.text.trim();
    await session.putMyCard(_name.text, avatar: avatar.isEmpty ? null : avatar);
  });

  Future<void> _ask() => _run(() async {
    final to = _to.text.trim();
    if (to.isEmpty) throw StateError('name a player id first');
    await session.requestFriend(to);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Friends')),
    body: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final card = session.myCard;
        final requests = session.socialRequests;
        return Column(
          children: <Widget>[
            CloseBanner(text: _error),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Card(
                    key: const Key('card-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'My card',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            'PUT /social/me/profile: a card admits you to '
                            'the graph; every relation needs one at both ends',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            key: const Key('card-state'),
                            card == null
                                ? (session.myCardAbsent
                                      ? 'No card yet'
                                      : 'Not loaded')
                                : 'Card: ${_nameOf(card.displayName, card.owner)}'
                                      '${card.avatar == null ? '' : ' (${card.avatar})'}',
                          ),
                          Row(
                            children: <Widget>[
                              SizedBox(
                                width: 160,
                                child: TextField(
                                  key: const Key('card-name'),
                                  controller: _name,
                                  decoration: const InputDecoration(
                                    labelText: 'display name',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 160,
                                child: TextField(
                                  key: const Key('card-avatar'),
                                  controller: _avatar,
                                  decoration: const InputDecoration(
                                    labelText: 'avatar id',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const Key('card-save'),
                                onPressed: _busy ? null : _saveCard,
                                child: const Text('Save'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Card(
                    key: const Key('requests-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Requests',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Row(
                            children: <Widget>[
                              SizedBox(
                                width: 240,
                                child: TextField(
                                  key: const Key('request-to'),
                                  controller: _to,
                                  decoration: const InputDecoration(
                                    labelText: 'player id to ask',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const Key('request-send'),
                                onPressed: _busy ? null : _ask,
                                child: const Text('Ask'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            key: const Key('requests-state'),
                            requests == null
                                ? 'Not loaded'
                                : '${requests.incoming.length} waiting for '
                                      'me, ${requests.outgoing.length} sent',
                          ),
                          if (requests != null)
                            for (final r in requests.incoming)
                              ListTile(
                                dense: true,
                                title: Text(_nameOf(r.displayName, r.owner)),
                                subtitle: Text(r.owner),
                                trailing: TextButton(
                                  key: Key('accept-${r.owner}'),
                                  onPressed: _busy
                                      ? null
                                      : () => _run(
                                          () => session.acceptFriend(r.owner),
                                        ),
                                  child: const Text('Accept'),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ),
                  Card(
                    key: const Key('friends-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  'Friends',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              TextButton(
                                key: const Key('social-refresh'),
                                onPressed: _busy
                                    ? null
                                    : () => _run(session.loadSocial),
                                child: const Text('Refresh'),
                              ),
                            ],
                          ),
                          Text(
                            key: const Key('friends-state'),
                            '${session.friends.length} friend(s)',
                          ),
                          for (final f in session.friends)
                            ListTile(
                              dense: true,
                              title: Text(_nameOf(f.displayName, f.owner)),
                              subtitle: Text(f.owner),
                              trailing: TextButton(
                                key: Key('unfriend-${f.owner}'),
                                onPressed: _busy
                                    ? null
                                    : () =>
                                          _run(() => session.unfriend(f.owner)),
                                child: const Text('Unfriend'),
                              ),
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
