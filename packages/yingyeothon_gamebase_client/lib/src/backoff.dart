import 'dart:math';

/// Exponential backoff with jitter.
final class BackoffOptions {
  /// Creates backoff options. Every field has the gateway's documented
  /// default; [random] is injectable for deterministic tests and defaults
  /// to a fresh [Random] per [Backoff], so two clients created together do
  /// not reconnect in lock-step after a gateway restart.
  const BackoffOptions({
    this.initialMs = 500,
    this.maxMs = 15000,
    this.factor = 2,
    this.jitter = 0.2,
    this.maxAttempts,
    this.random,
  });

  /// Delay before the first retry.
  final int initialMs;

  /// Upper bound on any delay.
  final int maxMs;

  /// Multiplier applied per attempt.
  final double factor;

  /// Fraction of the delay randomised on both sides.
  final double jitter;

  /// Give up after this many consecutive attempts; `null` is unbounded.
  final int? maxAttempts;

  /// Random source in `[0, 1)`.
  final double Function()? random;
}

/// Consecutive retry delays.
abstract interface class Backoff {
  /// Creates a backoff.
  factory Backoff([BackoffOptions? options]) =>
      _Backoff(options ?? const BackoffOptions());

  /// Consecutive attempts since the last [reset].
  int get attempts;

  /// The next delay in ms, or `null` when `maxAttempts` is exhausted.
  int? next();

  /// Starts over.
  void reset();
}

final class _Backoff implements Backoff {
  _Backoff(this._options) : _random = _options.random ?? Random().nextDouble;

  final BackoffOptions _options;
  final double Function() _random;
  int _attempts = 0;

  @override
  int get attempts => _attempts;

  @override
  int? next() {
    final max = _options.maxAttempts;
    if (max != null && _attempts >= max) return null;
    final base = min(
      _options.maxMs.toDouble(),
      _options.initialMs * pow(_options.factor, _attempts).toDouble(),
    );
    _attempts++;
    final spread = base * _options.jitter;
    return (base - spread + _random() * spread * 2).round();
  }

  @override
  void reset() => _attempts = 0;
}
