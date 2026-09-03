import 'package:flutter/material.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

/// A 20×20 grid: you in one colour, peers in another, facing as a tick.
class ZoneMap extends StatelessWidget {
  const ZoneMap({super.key, required this.self, required this.peers});

  final Peer self;
  final List<Peer> peers;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ZonePainter(
      self: self,
      peers: peers,
      selfColor: Theme.of(context).colorScheme.primary,
      peerColor: Theme.of(context).colorScheme.tertiary,
      gridColor: Theme.of(context).colorScheme.outlineVariant,
    ),
    child: const SizedBox.expand(),
  );
}

class _ZonePainter extends CustomPainter {
  _ZonePainter({
    required this.self,
    required this.peers,
    required this.selfColor,
    required this.peerColor,
    required this.gridColor,
  });

  final Peer self;
  final List<Peer> peers;
  final Color selfColor;
  final Color peerColor;
  final Color gridColor;

  static const int cells = 20;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.shortestSide / cells;
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 0; i <= cells; i++) {
      canvas.drawLine(
        Offset(i * cell, 0),
        Offset(i * cell, cells * cell),
        grid,
      );
      canvas.drawLine(
        Offset(0, i * cell),
        Offset(cells * cell, i * cell),
        grid,
      );
    }
    for (final peer in peers) {
      _draw(canvas, peer, cell, peerColor);
    }
    _draw(canvas, self, cell, selfColor);
  }

  void _draw(Canvas canvas, Peer peer, double cell, Color color) {
    final center = Offset((peer.x + 0.5) * cell, (peer.y + 0.5) * cell);
    canvas.drawCircle(center, cell * 0.35, Paint()..color = color);
    final facing = switch (peer.dir) {
      'n' => const Offset(0, -1),
      's' => const Offset(0, 1),
      'e' => const Offset(1, 0),
      'w' => const Offset(-1, 0),
      _ => Offset.zero,
    };
    if (facing != Offset.zero) {
      canvas.drawLine(
        center,
        center + facing * cell * 0.45,
        Paint()
          ..color = color
          ..strokeWidth = 2,
      );
    }
    final label = TextPainter(
      text: TextSpan(
        text: peer.userId,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, center + Offset(cell * 0.4, -cell * 0.6));
  }

  @override
  bool shouldRepaint(_ZonePainter old) =>
      old.self != self || old.peers != peers;
}
