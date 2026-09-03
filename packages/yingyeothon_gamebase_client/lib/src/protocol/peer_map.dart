import 'peer.dart';
import 'server_frames.dart';

/// What one frame did to a [PeerMap].
sealed class PeerChange {
  const PeerChange();
}

/// A `snapshot` replaced the map.
final class PeerSnapshot extends PeerChange {
  /// Creates a snapshot change.
  const PeerSnapshot(this.zone, this.peers);

  /// The zone now in view.
  final String zone;

  /// Everyone in view, you excluded.
  final List<Peer> peers;
}

/// A peer came into view.
final class PeerEntered extends PeerChange {
  /// Creates an enter change.
  const PeerEntered(this.peer);

  /// The peer.
  final Peer peer;
}

/// A peer left the view.
final class PeerLeft extends PeerChange {
  /// Creates a leave change.
  const PeerLeft(this.userId);

  /// Who.
  final String userId;
}

/// Peers moved.
final class PeerMoved extends PeerChange {
  /// Creates a move change.
  const PeerMoved(this.peers);

  /// The moved peers with their new positions.
  final List<Peer> peers;
}

/// Reduces the gateway's `snapshot` / `enter` / `leave` / `pos` frames into
/// the set of peers visible in the current zone.
///
/// A `snapshot` replaces everything (that is how a zone change starts);
/// frames for any other zone are ignored so a late `pos` from the old zone
/// cannot resurrect a peer that already left. Your own entry is dropped.
/// Insertion order is the order peers were first seen.
abstract interface class PeerMap {
  /// Creates an empty map for the receiver [selfUserId].
  factory PeerMap({required String selfUserId}) = _PeerMap;

  /// The zone of the last `snapshot`, or `null` before one arrives.
  String? get zone;

  /// Applies one frame; returns the change it produced, or `null` when the
  /// frame was ignored (another zone, an unknown peer, yourself, a frame
  /// this map does not handle).
  PeerChange? apply(LobbyServerFrame frame);

  /// A copy of the peer, or `null`.
  Peer? get(String userId);

  /// Copies of every peer, in insertion order.
  List<Peer> all();

  /// Forgets everything, including the zone.
  void reset();
}

final class _PeerMap implements PeerMap {
  _PeerMap({required String selfUserId}) : _self = selfUserId;

  final String _self;
  final Map<String, Peer> _peers = <String, Peer>{};
  String? _zone;

  @override
  String? get zone => _zone;

  @override
  PeerChange? apply(LobbyServerFrame frame) {
    switch (frame) {
      case SnapshotFrame(:final zone, :final peers):
        _zone = zone;
        _peers.clear();
        for (final peer in peers) {
          if (peer.userId != _self) _peers[peer.userId] = peer;
        }
        return PeerSnapshot(zone, all());
      case EnterFrame(:final zone, :final peer):
        if (_zone == null || zone != _zone || peer.userId == _self) {
          return null;
        }
        _peers[peer.userId] = peer;
        return PeerEntered(peer);
      case LeaveFrame(:final zone, :final userId):
        if (_zone == null || zone != _zone) return null;
        return _peers.remove(userId) == null ? null : PeerLeft(userId);
      case PosBroadcastFrame(:final zone, :final peers):
        if (_zone == null || zone != _zone) return null;
        final moved = <Peer>[];
        for (final update in peers) {
          if (update.userId == _self) continue;
          final existing = _peers[update.userId];
          if (existing == null) continue;
          final next = existing.withPosition(update.x, update.y, update.dir);
          _peers[update.userId] = next;
          moved.add(next);
        }
        return moved.isEmpty ? null : PeerMoved(moved);
      default:
        return null;
    }
  }

  @override
  Peer? get(String userId) => _peers[userId];

  @override
  List<Peer> all() => List<Peer>.unmodifiable(_peers.values);

  @override
  void reset() {
    _peers.clear();
    _zone = null;
  }
}
