import 'package:flutter/material.dart';
import 'package:yingyeothon_leaderboard_client/yingyeothon_leaderboard_client.dart';

import '../debug/debug_hooks.dart';
import '../session.dart';
import '../widgets/close_banner.dart';
import '../widgets/log_panel.dart';

/// The guide's case: a `submit: owner` board the player writes its own row
/// to, with the ranked page and the player's own rank.
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key, required this.session});

  static const String route = '/leaderboard';

  final Session session;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  final TextEditingController _score = TextEditingController(text: '70');
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
        session.openLb();
        await session.loadBoard();
        if (offlineAutostartLb) await _submit();
      });
    });
  }

  @override
  void dispose() {
    _score.dispose();
    // notify: false — the tree is locked during dispose (rules/flutter.md).
    session.closeLb(notify: false);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on LeaderboardException catch (e) {
      // The code and the status: never an owner, a meta or the token.
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

  static String _describe(LeaderboardException e) {
    if (e.isUnauthorized) return 'refused (401): sign in again';
    if (e.isForbidden) return 'forbidden (403): not yours to write';
    if (e.isNotFound) return 'not found (404): create the board first';
    if (e.isBoardFull) return 'full (409 board_full)';
    if (e.status == 0) return 'network: ${e.code}';
    return '$e';
  }

  Future<void> _submit() => _run(() async {
    final score = int.tryParse(_score.text.trim());
    if (score == null) throw StateError('score must be an integer');
    await session.submitScore(score);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Leaderboard')),
    body: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final info = session.boardInfo;
        final page = session.boardPage;
        final mine = session.myScore;
        return Column(
          children: <Widget>[
            CloseBanner(text: _error),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Card(
                    key: const Key('board-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  'Board ${Session.boardName}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              TextButton(
                                key: const Key('board-refresh'),
                                onPressed: _busy
                                    ? null
                                    : () => _run(session.loadBoard),
                                child: const Text('Refresh'),
                              ),
                            ],
                          ),
                          Text(
                            key: const Key('board-shape'),
                            info == null
                                ? 'Not loaded'
                                : 'submit ${info.submit}, rule ${info.rule}, '
                                      'order ${info.order}, periods '
                                      '${info.periods.map((b) => b.period).join('/')}',
                          ),
                          const SizedBox(height: 8),
                          if (page == null)
                            const Text('No page yet')
                          else ...<Widget>[
                            Text(
                              key: const Key('board-bucket'),
                              '${page.bucket.period} · ${page.total} row(s)',
                            ),
                            for (final entry in page.entries)
                              ListTile(
                                dense: true,
                                leading: Text('#${entry.rank}'),
                                title: Text(entry.owner),
                                trailing: Text('${entry.score}'),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Card(
                    key: const Key('mine-card'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'My score',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Text(
                            'PUT /lb/{board}/scores/me: on a best board a '
                            'worse score changes nothing',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            key: const Key('mine-state'),
                            mine == null
                                ? (session.myScoreAbsent
                                      ? 'No row of mine yet'
                                      : 'Not loaded')
                                : 'Stored ${mine.score}, rank ${mine.rank} '
                                      'of ${mine.total}',
                          ),
                          Row(
                            children: <Widget>[
                              SizedBox(
                                width: 160,
                                child: TextField(
                                  key: const Key('mine-score'),
                                  controller: _score,
                                  decoration: const InputDecoration(
                                    labelText: 'score',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const Key('mine-submit'),
                                onPressed: _busy ? null : _submit,
                                child: const Text('Submit'),
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
}
