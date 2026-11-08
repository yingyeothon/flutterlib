import 'dart:math';

import 'package:yingyeothon_logger/yingyeothon_logger.dart';
import 'package:yingyeothon_tracer_client/yingyeothon_tracer_client.dart';

import 'fake_http_client.dart';

/// A [Random] whose bytes count up and whose doubles are fixed, so ids and
/// jitter are the same on every run.
final class SequenceRandom implements Random {
  SequenceRandom({this.fixed = 0.5});
  int _next = 0;
  final double fixed;
  @override
  int nextInt(int max) => _next++ % max;
  @override
  double nextDouble() => fixed;
  @override
  bool nextBool() => nextInt(2) == 1;
}

/// A clock that starts at [start] and advances 1 ms per read.
DateTime Function() steppingClock([DateTime? start]) {
  var t = start ?? DateTime.utc(2026, 11, 8, 6, 42, 16, 4);
  return () {
    final now = t;
    t = t.add(const Duration(milliseconds: 1));
    return now;
  };
}

/// Records [LogWriters.format] lines.
final class CapturingLogWriter implements LogWriter {
  final List<String> lines = [];
  @override
  void debug(String m, [Map<String, Object?>? c]) =>
      lines.add(LogWriters.format(LogSeverity.debug, m, c));
  @override
  void info(String m, [Map<String, Object?>? c]) =>
      lines.add(LogWriters.format(LogSeverity.info, m, c));
  @override
  void warn(String m, [Map<String, Object?>? c]) =>
      lines.add(LogWriters.format(LogSeverity.warn, m, c));
  @override
  void error(String m, [Map<String, Object?>? c]) =>
      lines.add(LogWriters.format(LogSeverity.error, m, c));
}

/// A client over [http] with fixed ids and clock.
TracerClient makeClient(
  FakeHttp http, {
  String dsn = fixtureDsn,
  Map<String, String> tags = const {},
  Logger? logger,
  int logBatchSize = 100,
  int breadcrumbCapacity = 500,
  int maxQueuedEnvelopes = 32,
  int maxQueuedBytes = 48 * 1024 * 1024,
  bool compress = true,
  double jitter = 0.5,
  bool allowHttpLoopback = false,
}) => TracerClient(
  TracerOptions(
    dsn: dsn,
    release: 'playground@0.1.0+1',
    dist: 'abc1234',
    environment: 'debug',
    tags: tags,
    userId: '00000000000000000000000000000000',
    client: http,
    logger: logger,
    now: steppingClock(),
    random: SequenceRandom(fixed: jitter),
    logBatchSize: logBatchSize,
    breadcrumbCapacity: breadcrumbCapacity,
    maxQueuedEnvelopes: maxQueuedEnvelopes,
    maxQueuedBytes: maxQueuedBytes,
    compress: compress,
    allowHttpLoopback: allowHttpLoopback,
  ),
);
