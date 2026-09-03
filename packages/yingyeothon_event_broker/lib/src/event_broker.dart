import 'dart:async';

/// A handler for events of type [T]. May be synchronous or return a Future.
typedef EventHandler<T extends Object> = FutureOr<void> Function(T event);

/// The subscription half of a broker.
abstract interface class EventListenable {
  /// Calls [handler] for every event fired as [T]. Returns `this` for
  /// chaining.
  EventListenable on<T extends Object>(EventHandler<T> handler);

  /// Calls [handler] for the next event fired as [T], then removes it —
  /// before it runs, so a handler that throws is still gone.
  EventListenable once<T extends Object>(EventHandler<T> handler);

  /// Removes the first registration of [handler] under [T].
  EventListenable off<T extends Object>(EventHandler<T> handler);
}

/// A broker that fires events to type-keyed handlers.
///
/// The key is the **static** type argument: `fire<Base>(derived)` reaches
/// `on<Base>` handlers and not `on<Derived>` ones. Handlers run in
/// registration order, one at a time, over a snapshot taken when [fire] is
/// called; a handler added or removed during a fire does not affect that
/// fire. The first handler that throws stops the fire and the error
/// propagates.
abstract interface class EventBroker implements EventListenable {
  /// Creates an empty broker.
  factory EventBroker() = _EventBroker;

  /// Fires [event] to every handler registered under [T]. Completes with
  /// `true` when at least one handler ran.
  Future<bool> fire<T extends Object>(T event);
}

final class _Registration {
  _Registration(this.handler, {required this.once});
  final Function handler;
  final bool once;
}

final class _EventBroker implements EventBroker {
  final Map<Type, List<_Registration>> _handlers =
      <Type, List<_Registration>>{};

  @override
  EventListenable on<T extends Object>(EventHandler<T> handler) {
    _list<T>().add(_Registration(handler, once: false));
    return this;
  }

  @override
  EventListenable once<T extends Object>(EventHandler<T> handler) {
    _list<T>().add(_Registration(handler, once: true));
    return this;
  }

  @override
  EventListenable off<T extends Object>(EventHandler<T> handler) {
    final list = _handlers[T];
    if (list == null) return this;
    final index = list.indexWhere((r) => r.handler == handler);
    if (index >= 0) list.removeAt(index);
    if (list.isEmpty) _handlers.remove(T);
    return this;
  }

  @override
  Future<bool> fire<T extends Object>(T event) async {
    final list = _handlers[T];
    if (list == null || list.isEmpty) return false;
    final snapshot = List<_Registration>.of(list);
    for (final registration in snapshot) {
      if (registration.once) {
        list.remove(registration);
        if (list.isEmpty) _handlers.remove(T);
      }
      final handler = registration.handler as EventHandler<T>;
      await handler(event);
    }
    return true;
  }

  List<_Registration> _list<T extends Object>() =>
      _handlers.putIfAbsent(T, () => <_Registration>[]);
}
