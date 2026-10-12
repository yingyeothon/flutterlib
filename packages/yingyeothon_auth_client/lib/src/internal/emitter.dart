import 'dart:async';
import 'dart:collection';

/// A synchronous broadcast stream that survives re-entrancy.
///
/// `StreamController.broadcast(sync: true)` throws when [emit] is called from
/// inside a listener (a handler that sends a frame which the fake gateway
/// answers synchronously does exactly that). This queues the nested emit and
/// drains it after the current one, so order is preserved and the state
/// machine never sees an event out of sequence.
final class Emitter<T> {
  final StreamController<T> _controller = StreamController<T>.broadcast(
    sync: true,
  );
  final Queue<T> _pending = Queue<T>();
  bool _firing = false;

  /// The stream handlers subscribe to.
  Stream<T> get stream => _controller.stream;

  /// Whether anyone is listening.
  bool get hasListener => _controller.hasListener;

  /// Delivers [value] to every listener, now or as soon as the current
  /// delivery finishes.
  void emit(T value) {
    if (_controller.isClosed) return;
    if (_firing) {
      _pending.add(value);
      return;
    }
    _firing = true;
    try {
      _controller.add(value);
      while (_pending.isNotEmpty) {
        _controller.add(_pending.removeFirst());
      }
    } finally {
      _firing = false;
    }
  }

  /// Closes the stream; later emits are dropped.
  Future<void> close() => _controller.close();
}
