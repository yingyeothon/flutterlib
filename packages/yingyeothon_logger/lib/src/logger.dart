import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// Severity levels, least to most severe, with [none] above all of them.
enum LogSeverity {
  /// Diagnostic detail; still never a token, a frame body or a payload.
  debug,

  /// Milestones: connected, reconnecting, stopped.
  info,

  /// Something the peer refused or the SDK worked around.
  warn,

  /// A failure the caller must act on.
  error,

  /// Suppresses everything; the threshold of [nullLogger].
  none,
}

/// A sink for log lines. Implement this to route logs somewhere.
abstract interface class LogWriter {
  /// Writes a debug line.
  void debug(String message, [JsonObject? context]);

  /// Writes an info line.
  void info(String message, [JsonObject? context]);

  /// Writes a warning.
  void warn(String message, [JsonObject? context]);

  /// Writes an error.
  void error(String message, [JsonObject? context]);
}

/// A [LogWriter] with a threshold. Lines below [severity] are dropped before
/// the writer sees them; the threshold is read on every call, so it can be
/// raised at runtime to debug one session.
abstract interface class Logger implements LogWriter {
  /// The current threshold.
  LogSeverity get severity;
  set severity(LogSeverity value);

  /// Whether a line at [level] would be written right now.
  bool isEnabled(LogSeverity level);
}

/// One function that receives every line, for adapters such as Flutter's
/// `debugPrint`: `LogWriters.fromFunction((s, m, c) => debugPrint(...))`.
typedef LogWriteFunction = void Function(
  LogSeverity severity,
  String message,
  JsonObject? context,
);

/// Ready-made writers and the shared line format.
abstract final class LogWriters {
  /// Writes to standard output through `print`.
  static final LogWriter console = fromFunction(
    (severity, message, context) => _print(format(severity, message, context)),
  );

  /// Drops everything. Combining with it is a no-op.
  static const LogWriter none = _NullWriter();

  /// Adapts a function into a writer.
  static LogWriter fromFunction(LogWriteFunction write) =>
      _FunctionWriter(write);

  /// Fans one line out to several writers, in order. [none] and [nullLogger]
  /// are skipped by identity; any other writer is kept even if it drops
  /// everything itself.
  static LogWriter combine(Iterable<LogWriter> writers) {
    final kept = writers
        .where((w) => !identical(w, none) && !identical(w, nullLogger))
        .toList(growable: false);
    if (kept.isEmpty) return none;
    if (kept.length == 1) return kept.single;
    return _CombinedWriter(kept);
  }

  /// `[info] message {"k":"v"}`; the context is omitted when null or empty.
  /// Deterministic, so a test can assert a whole line.
  static String format(
    LogSeverity severity,
    String message,
    JsonObject? context,
  ) {
    final head = '[${severity.name}] $message';
    if (context == null || context.isEmpty) return head;
    return '$head ${Json.encode(context)}';
  }
}

// `print` is what `avoid_print` forbids in library code; this is the one
// writer whose job is to print.
// ignore: avoid_print
void _print(String line) => print(line);

/// The default logger of every package: threshold [LogSeverity.none].
final Logger nullLogger = _FilteredLogger(LogSeverity.none, LogWriters.none);

/// A [Logger] that forwards lines at or above [severity] to [writer].
Logger createFilteredLogger({
  required LogSeverity severity,
  required LogWriter writer,
}) => _FilteredLogger(severity, writer);

/// A [Logger] over [LogWriters.console].
Logger createConsoleLogger([LogSeverity severity = LogSeverity.info]) =>
    _FilteredLogger(severity, LogWriters.console);

final class _NullWriter implements LogWriter {
  const _NullWriter();
  @override
  void debug(String message, [JsonObject? context]) {}
  @override
  void info(String message, [JsonObject? context]) {}
  @override
  void warn(String message, [JsonObject? context]) {}
  @override
  void error(String message, [JsonObject? context]) {}
}

final class _FunctionWriter implements LogWriter {
  _FunctionWriter(this._write);
  final LogWriteFunction _write;
  @override
  void debug(String message, [JsonObject? context]) =>
      _write(LogSeverity.debug, message, context);
  @override
  void info(String message, [JsonObject? context]) =>
      _write(LogSeverity.info, message, context);
  @override
  void warn(String message, [JsonObject? context]) =>
      _write(LogSeverity.warn, message, context);
  @override
  void error(String message, [JsonObject? context]) =>
      _write(LogSeverity.error, message, context);
}

final class _CombinedWriter implements LogWriter {
  _CombinedWriter(this._writers);
  final List<LogWriter> _writers;
  @override
  void debug(String message, [JsonObject? context]) {
    for (final w in _writers) {
      w.debug(message, context);
    }
  }

  @override
  void info(String message, [JsonObject? context]) {
    for (final w in _writers) {
      w.info(message, context);
    }
  }

  @override
  void warn(String message, [JsonObject? context]) {
    for (final w in _writers) {
      w.warn(message, context);
    }
  }

  @override
  void error(String message, [JsonObject? context]) {
    for (final w in _writers) {
      w.error(message, context);
    }
  }
}

final class _FilteredLogger implements Logger {
  _FilteredLogger(this.severity, this._writer);
  final LogWriter _writer;

  @override
  LogSeverity severity;

  @override
  bool isEnabled(LogSeverity level) =>
      level != LogSeverity.none && level.index >= severity.index;

  @override
  void debug(String message, [JsonObject? context]) {
    if (isEnabled(LogSeverity.debug)) _writer.debug(message, context);
  }

  @override
  void info(String message, [JsonObject? context]) {
    if (isEnabled(LogSeverity.info)) _writer.info(message, context);
  }

  @override
  void warn(String message, [JsonObject? context]) {
    if (isEnabled(LogSeverity.warn)) _writer.warn(message, context);
  }

  @override
  void error(String message, [JsonObject? context]) {
    if (isEnabled(LogSeverity.error)) _writer.error(message, context);
  }
}
