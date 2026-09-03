import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// One retained position. Immutable; [PeerMap] hands out fresh copies.
final class Peer {
  /// Creates a peer.
  const Peer({
    required this.userId,
    required this.x,
    required this.y,
    this.dir,
  });

  /// Reads a peer object; `null` when it has no string `userId`.
  static Peer? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final userId = value.getString('userId');
    if (userId == null) return null;
    return Peer(
      userId: userId,
      x: value.getDouble('x') ?? 0,
      y: value.getDouble('y') ?? 0,
      dir: value.getString('dir'),
    );
  }

  /// Who.
  final String userId;

  /// Position; the wire carries `float64`.
  final double x;

  /// Position.
  final double y;

  /// The game's own facing token, at most 16 bytes; `null` when unset.
  final String? dir;

  /// A copy at another position. An omitted [dir] clears the facing: a
  /// `pos` entry without one means the peer stopped announcing it.
  Peer withPosition(double x, double y, String? dir) =>
      Peer(userId: userId, x: x, y: y, dir: dir);

  @override
  bool operator ==(Object other) =>
      other is Peer &&
      other.userId == userId &&
      other.x == x &&
      other.y == y &&
      other.dir == dir;

  @override
  int get hashCode => Object.hash(userId, x, y, dir);

  @override
  String toString() => 'Peer($userId, $x, $y, $dir)';
}
