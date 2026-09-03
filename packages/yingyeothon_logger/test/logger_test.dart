import 'package:test/test.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

/// Captures formatted lines. The same shape the other packages' suites use.
final class CapturingWriter implements LogWriter {
  final List<String> lines = <String>[];
  void _add(LogSeverity s, String m, Map<String, Object?>? c) =>
      lines.add(LogWriters.format(s, m, c));
  @override
  void debug(String message, [Map<String, Object?>? context]) =>
      _add(LogSeverity.debug, message, context);
  @override
  void info(String message, [Map<String, Object?>? context]) =>
      _add(LogSeverity.info, message, context);
  @override
  void warn(String message, [Map<String, Object?>? context]) =>
      _add(LogSeverity.warn, message, context);
  @override
  void error(String message, [Map<String, Object?>? context]) =>
      _add(LogSeverity.error, message, context);
}

void main() {
  test('format is deterministic and omits an empty context', () {
    expect(LogWriters.format(LogSeverity.info, 'hi', null), '[info] hi');
    expect(LogWriters.format(LogSeverity.warn, 'hi', {}), '[warn] hi');
    expect(
      LogWriters.format(LogSeverity.error, 'hi', {'a': 1, 'b': 'x'}),
      '[error] hi {"a":1,"b":"x"}',
    );
  });

  test('threshold is read on every call', () {
    final writer = CapturingWriter();
    final logger = createFilteredLogger(
      severity: LogSeverity.warn,
      writer: writer,
    );
    logger.info('dropped');
    logger.warn('kept');
    expect(logger.isEnabled(LogSeverity.info), isFalse);
    logger.severity = LogSeverity.debug;
    expect(logger.isEnabled(LogSeverity.debug), isTrue);
    logger.debug('now kept', {'n': 1});
    logger.error('always');
    expect(writer.lines, [
      '[warn] kept',
      '[debug] now kept {"n":1}',
      '[error] always',
    ]);
  });

  test('none suppresses everything and is never enabled', () {
    final writer = CapturingWriter();
    final logger = createFilteredLogger(
      severity: LogSeverity.none,
      writer: writer,
    );
    logger.error('no');
    expect(writer.lines, isEmpty);
    expect(logger.isEnabled(LogSeverity.error), isFalse);
    expect(logger.isEnabled(LogSeverity.none), isFalse);
    expect(nullLogger.severity, LogSeverity.none);
    nullLogger.error('no');
  });

  test('combine fans out in order and skips only the null writers', () {
    final a = CapturingWriter();
    final b = CapturingWriter();
    final combined = LogWriters.combine([a, LogWriters.none, nullLogger, b]);
    combined.info('x');
    combined.debug('d');
    combined.warn('w');
    combined.error('e');
    expect(a.lines, ['[info] x', '[debug] d', '[warn] w', '[error] e']);
    expect(b.lines, a.lines);
    expect(LogWriters.combine([LogWriters.none]), same(LogWriters.none));
    expect(LogWriters.combine([a]), same(a));
  });

  test('fromFunction receives the severity, message and context', () {
    final seen = <String>[];
    final writer = LogWriters.fromFunction(
      (s, m, c) => seen.add(LogWriters.format(s, m, c)),
    );
    writer.debug('a');
    writer.info('b', {'k': true});
    writer.warn('c');
    writer.error('d');
    expect(seen, ['[debug] a', '[info] b {"k":true}', '[warn] c', '[error] d']);
  });

  test('console logger defaults to info', () {
    final logger = createConsoleLogger();
    expect(logger.severity, LogSeverity.info);
    expect(logger.isEnabled(LogSeverity.debug), isFalse);
  });
}
