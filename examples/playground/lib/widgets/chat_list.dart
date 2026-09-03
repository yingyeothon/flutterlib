import 'package:flutter/material.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import '../session.dart';

/// Chat and game events, with a composer for `say` and `event`.
class ChatList extends StatefulWidget {
  const ChatList({super.key, required this.session});

  final Session session;

  @override
  State<ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<ChatList> {
  final TextEditingController _text = TextEditingController();
  final TextEditingController _to = TextEditingController();
  SayScope _scope = SayScope.zone;
  String? _error;

  Session get session => widget.session;

  @override
  void dispose() {
    _text.dispose();
    _to.dispose();
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

  void _say() => _guard(() {
    session.lobby?.say(
      scope: _scope,
      text: _text.text,
      to: _scope == SayScope.user ? _to.text.trim() : null,
    );
    _text.clear();
  });

  void _event() => _guard(() {
    session.lobby?.event(
      scope: _scope,
      name: 'wave',
      payload: <String, Object?>{'text': _text.text},
      to: _scope == SayScope.user ? _to.text.trim() : null,
    );
    _text.clear();
  });

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      for (final s in session.chat) '${s.from} (${s.scope}): ${s.text}',
      for (final e in session.events)
        '${e.from} (${e.scope}) event ${e.name}: ${e.payload}',
    ];
    return Column(
      children: <Widget>[
        Expanded(
          child: ListView.builder(
            key: const Key('chat-lines'),
            itemCount: lines.length,
            itemBuilder: (context, i) =>
                ListTile(dense: true, title: Text(lines[i])),
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: <Widget>[
              DropdownButton<SayScope>(
                value: _scope,
                items: SayScope.values
                    .map(
                      (s) => DropdownMenuItem<SayScope>(
                        value: s,
                        child: Text(s.name),
                      ),
                    )
                    .toList(),
                onChanged: (s) {
                  if (s != null) setState(() => _scope = s);
                },
              ),
              if (_scope == SayScope.user) ...<Widget>[
                const SizedBox(width: 8),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _to,
                    decoration: const InputDecoration(labelText: 'to'),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('chat-text'),
                  controller: _text,
                  decoration: const InputDecoration(labelText: 'say'),
                  onSubmitted: (_) => _say(),
                ),
              ),
              IconButton(
                key: const Key('chat-send'),
                onPressed: _say,
                icon: const Icon(Icons.send),
              ),
              IconButton(
                key: const Key('event-send'),
                tooltip: 'send as event',
                onPressed: _event,
                icon: const Icon(Icons.waving_hand),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
