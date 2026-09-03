import 'package:flutter/material.dart';

/// The one-line status the connection lifecycle produces: reconnecting,
/// stopped, aborted, finished. Hidden when there is nothing to say.
class CloseBanner extends StatelessWidget {
  const CloseBanner({super.key, required this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final message = text;
    if (message == null) return const SizedBox.shrink();
    return Material(
      key: const Key('close-banner'),
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}
