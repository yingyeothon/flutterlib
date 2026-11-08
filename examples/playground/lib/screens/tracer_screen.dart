import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:yingyeothon_tracer_flutter/yingyeothon_tracer_flutter.dart';

import '../session.dart';
import '../widgets/log_panel.dart';

/// Debug data to tracer: steps (breadcrumb + log), a warning log line, and
/// "report this" (event + screenshot + view hierarchy, then a note). Off
/// unless the build passed `--dart-define=TRACER_DSN=…`.
class TracerScreen extends StatefulWidget {
  const TracerScreen({super.key, required this.session});
  static const route = '/tracer';
  final Session session;
  @override
  State<TracerScreen> createState() => _TracerScreenState();
}

class _TracerScreenState extends State<TracerScreen> {
  int _steps = 0;

  TracerClient get _tracer => Tracer.current;

  @override
  void initState() {
    super.initState();
    // A smoke run with no input tooling: one of everything, the note fixed.
    if (kDebugMode && const bool.fromEnvironment('YYT_TRACER_AUTOSTART')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autostart());
    }
  }

  Future<void> _autostart() async {
    // Let the push transition finish, so the screenshot shows this screen.
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!mounted || !_tracer.enabled) return;
    _step();
    _warn();
    final id = await _tracer.report(
      'playground autostart report',
      screenshot: await TracerScreenshot.capture(),
      attachments: [
        TracerAttachment.viewHierarchy(TracerScreenshot.viewHierarchy()),
      ],
    );
    await _tracer.feedback('playground autostart note', eventId: id);
    await _tracer.flush();
    widget.session.note('tracer: autostart report $id');
    if (mounted) setState(() {});
  }

  void _step() {
    _steps++;
    _tracer.trace('playground', 'step $_steps', data: {'step': _steps});
    widget.session.note('tracer: step $_steps');
    setState(() {});
  }

  void _warn() {
    _tracer.log(
      TracerLevel.warning,
      'playground warning',
      attributes: {'steps': _steps, 'debug': kDebugMode},
    );
    widget.session.note('tracer: warning logged');
    setState(() {});
  }

  Future<void> _report() async {
    final id = await TracerReportButton.reportThis(
      context,
      message: 'playground report',
    );
    widget.session.note(id == null ? 'tracer: not sent' : 'tracer: report $id');
    if (mounted) setState(() {});
  }

  Future<void> _flush() async {
    await _tracer.flush();
    if (mounted) setState(() {});
  }

  String _status() {
    final t = _tracer;
    final s = t.stats;
    return switch (t.state) {
      TracerState.off =>
        'Tracer is off: build with --dart-define=TRACER_DSN=… '
            '(yyt tracer dsn <res>).',
      TracerState.stopped => 'Tracer stopped: the ingest refused the key.',
      TracerState.closed => 'Tracer closed.',
      TracerState.active =>
        'Tracer active: ${s.envelopesSent} sent, ${s.queued} queued, '
            'dropped ${s.dropped.isEmpty ? 'none' : s.dropped}.',
    };
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Tracer'),
      actions: const [TracerReportButton(message: 'playground report')],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(_status(), key: const Key('tracer-status')),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const Key('tracer-step'),
              onPressed: _tracer.enabled ? _step : null,
              child: const Text('Trace a step'),
            ),
            FilledButton.tonal(
              key: const Key('tracer-warn'),
              onPressed: _tracer.enabled ? _warn : null,
              child: const Text('Log a warning'),
            ),
            if (kDebugMode)
              FilledButton.tonal(
                key: const Key('tracer-report-action'),
                onPressed: _tracer.enabled ? _report : null,
                child: const Text('Report this'),
              ),
            OutlinedButton(
              key: const Key('tracer-flush'),
              onPressed: _tracer.enabled ? _flush : null,
              child: const Text('Flush'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(height: 200, child: LogPanel(session: widget.session)),
      ],
    ),
  );
}
