import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

import '../map_layout.dart';

/// The fetched map's grid: blocked cells filled, you in one colour, peers in
/// another, facing as a tick.
class ZoneMap extends StatelessWidget {
  const ZoneMap({
    super.key,
    required this.layout,
    required this.self,
    required this.peers,
  });

  final MapLayout layout;
  final Peer self;
  final List<Peer> peers;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ZonePainter(
      layout: layout,
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
    required this.layout,
    required this.self,
    required this.peers,
    required this.selfColor,
    required this.peerColor,
    required this.gridColor,
  });

  final MapLayout layout;
  final Peer self;
  final List<Peer> peers;
  final Color selfColor;
  final Color peerColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = layout.width;
    final h = layout.height;
    final cell = math.min(size.width / w, size.height / h);
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var i = 0; i <= w; i++) {
      canvas.drawLine(Offset(i * cell, 0), Offset(i * cell, h * cell), grid);
    }
    for (var i = 0; i <= h; i++) {
      canvas.drawLine(Offset(0, i * cell), Offset(w * cell, i * cell), grid);
    }
    final wall = Paint()..color = gridColor;
    for (final (x, y) in layout.blocked) {
      canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), wall);
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
      old.layout != layout || old.self != self || old.peers != peers;
}
