/// A type-keyed asynchronous event broker.
///
/// Handlers subscribe by the static type of the payload (`on<PlayerDied>`),
/// so a misspelt event is a compile error rather than a silent no-op, and
/// `fire` awaits every handler in registration order.
library;

export 'src/event_broker.dart' show EventBroker, EventHandler, EventListenable;
