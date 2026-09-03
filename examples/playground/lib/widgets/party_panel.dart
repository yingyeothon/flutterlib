import 'package:flutter/material.dart';

import '../session.dart';

/// The roster and the party commands.
class PartyPanel extends StatefulWidget {
  const PartyPanel({super.key, required this.session});

  final Session session;

  @override
  State<PartyPanel> createState() => _PartyPanelState();
}

class _PartyPanelState extends State<PartyPanel> {
  final TextEditingController _invitee = TextEditingController();
  String? _error;

  Session get session => widget.session;

  @override
  void dispose() {
    _invitee.dispose();
    super.dispose();
  }

  void _guard(void Function() action) {
    try {
      action();
      setState(() => _error = null);
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final lobby = session.lobby;
    final roster = lobby?.roster;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            lobby?.partyId == null ? 'No party' : 'Party ${lobby!.partyId}',
            key: const Key('party-title'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (roster != null) ...<Widget>[
            Text('leader: ${roster.leaderId}  max: ${roster.max}'),
            for (final m in roster.members)
              Text('• ${m.userId}${m.online ? '' : ' (offline)'}'),
            if (roster.invited.isNotEmpty)
              Text('invited: ${roster.invited.join(', ')}'),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              FilledButton.tonal(
                key: const Key('party-create'),
                onPressed: () => _guard(() => lobby?.party.create()),
                child: const Text('Create'),
              ),
              FilledButton.tonal(
                key: const Key('party-leave'),
                onPressed: () => _guard(() => lobby?.party.leave()),
                child: const Text('Leave'),
              ),
              FilledButton.tonal(
                onPressed: () => _guard(() => lobby?.party.list()),
                child: const Text('Refresh'),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('party-invitee'),
                  controller: _invitee,
                  decoration: const InputDecoration(
                    labelText: 'invite user id',
                  ),
                ),
              ),
              IconButton(
                key: const Key('party-invite'),
                onPressed: () =>
                    _guard(() => lobby?.party.invite(_invitee.text.trim())),
                icon: const Icon(Icons.person_add),
              ),
            ],
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
