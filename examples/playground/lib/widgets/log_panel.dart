import 'package:flutter/material.dart';

import '../session.dart';

/// The SDK's log lines and the app's notes, newest last.
class LogPanel extends StatelessWidget {
  const LogPanel({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ListView.builder(
        key: const Key('log-panel'),
        reverse: true,
        itemCount: session.log.length,
        itemBuilder: (context, i) {
          final line = session.log[session.log.length - 1 - i];
          return Text(
            '${line.at.toIso8601String().substring(11, 19)} ${line.text}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          );
        },
      ),
    ),
  );
}
