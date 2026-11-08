import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../tracer_client.dart';

/// `sdk` of every envelope header and event.
const Map<String, String> sdkInfo = {
  'name': 'yyt.dart',
  'version': tracerSdkVersion,
};

/// Content type of a log container item.
const String logContentType = 'application/vnd.sentry.items.log+json';

/// Room left for an item header line and newlines when sizing an envelope.
const int itemOverhead = 512;

/// [bytes] random bytes as lowercase hex.
String hexId(Random random, int bytes) {
  final b = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    b.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// RFC 3339 in UTC, as event and breadcrumb timestamps are written.
String rfc3339(DateTime t) => t.toUtc().toIso8601String();

/// Float seconds, as log entry timestamps are written.
double epochSeconds(DateTime t) => t.microsecondsSinceEpoch / 1e6;

/// The event `level` of [level].
String eventLevel(TracerLevel level) => level.name;

/// The log `level` of [level].
String logLevel(TracerLevel level) =>
    level == TracerLevel.warning ? 'warn' : level.name;

/// The log `severity_number` of [level] (OpenTelemetry's ranges).
int severityNumber(TracerLevel level) => switch (level) {
  TracerLevel.debug => 5,
  TracerLevel.info => 9,
  TracerLevel.warning => 13,
  TracerLevel.error => 17,
  TracerLevel.fatal => 21,
};

/// [s] cut to at most [maxBytes] UTF-8 bytes on a character boundary.
String clipUtf8(String s, int maxBytes) {
  if (s.length * 3 <= maxBytes) return s;
  final bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return s;
  var cut = maxBytes;
  while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
    cut--;
  }
  return utf8.decode(bytes.sublist(0, cut));
}

/// A JSON-safe copy of [value]: maps get string keys (clipped), iterables
/// become lists, non-finite doubles and unknown objects become strings,
/// strings are clipped, nesting stops at depth 8, collections at 200 entries
/// and the whole copy at 2000 values (a cyclic or wide graph stays cheap).
/// Never throws.
Object? jsonSafe(Object? value) => _safe(value, 0, _Budget());

final class _Budget {
  int left = 2000;
}

Object? _safe(Object? value, int depth, _Budget budget) {
  if (--budget.left < 0) return '…';
  try {
    return switch (value) {
      null || bool() || int() => value,
      double() => value.isFinite ? value : value.toString(),
      String() => clipUtf8(value, TracerLimits.maxTextBytes),
      DateTime() => rfc3339(value),
      Map<Object?, Object?>() when depth < 8 => {
        for (final e in value.entries.take(200))
          if (budget.left > 0)
            clipUtf8(_text(e.key), 200): _safe(e.value, depth + 1, budget),
      },
      Iterable<Object?>() when depth < 8 => [
        for (final v in value.take(200))
          if (budget.left > 0) _safe(v, depth + 1, budget),
      ],
      Map<Object?, Object?>() || Iterable<Object?>() => '…',
      _ => clipUtf8(value.toString(), TracerLimits.maxTextBytes),
    };
  } on Object {
    return '<unprintable>';
  }
}

String _text(Object? key) {
  try {
    return '$key';
  } on Object {
    return '<unprintable>';
  }
}

/// A typed log attribute `{"value", "type"}`; null for a null [value].
Map<String, Object?>? typedAttribute(Object? value) {
  final safe = jsonSafe(value);
  return switch (safe) {
    null => null,
    bool() => {'value': safe, 'type': 'boolean'},
    int() => {'value': safe, 'type': 'integer'},
    double() => {'value': safe, 'type': 'double'},
    String() => {'value': safe, 'type': 'string'},
    _ => {
      'value': clipUtf8(jsonEncode(safe), TracerLimits.maxTextBytes),
      'type': 'string',
    },
  };
}

/// UTF-8 JSON of [value] (already JSON-safe).
Uint8List jsonBytes(Object? value) => utf8.encode(jsonEncode(value));

/// One envelope item: its header fields (without `length`) and payload.
final class WireItem {
  /// An item.
  WireItem(this.header, this.payload);

  /// `type` and the type's own fields, in wire order.
  final Map<String, Object?> header;

  /// Payload bytes.
  final Uint8List payload;
}

/// Encodes an envelope: the header line, then per item a header line with
/// an explicit `length` and the payload, each followed by a newline.
Uint8List encodeEnvelope(Map<String, Object?> header, List<WireItem> items) {
  final out = BytesBuilder(copy: false)
    ..add(jsonBytes(header))
    ..addByte(0x0A);
  for (final item in items) {
    out
      ..add(jsonBytes({...item.header, 'length': item.payload.length}))
      ..addByte(0x0A)
      ..add(item.payload)
      ..addByte(0x0A);
  }
  return out.takeBytes();
}

final RegExp _vmFrame = RegExp(
  r'^#\d+\s+(.+?)\s+\((.+?)(?::(\d+))?(?::(\d+))?\)$',
);

/// Frames of a Dart VM [stackTrace], oldest first (the Sentry order), the
/// innermost 200 kept, with sentry-dart's fields. `filename` is
/// `<package>/<path>` (or the path after `/lib/`), since the read API shows
/// it and not `abs_path`, and tracer groups by it. A trace in another
/// format yields no frames.
List<Map<String, Object?>> stackFrames(StackTrace stackTrace) {
  final frames = <Map<String, Object?>>[];
  for (final line in stackTrace.toString().split('\n')) {
    final m = _vmFrame.firstMatch(line.trim());
    if (m == null) continue;
    final uri = m.group(2)!;
    final pkg = RegExp(r'^package:([^/]+)/(.+)$').firstMatch(uri);
    final lib = uri.lastIndexOf('/lib/');
    final file = pkg != null
        ? '${pkg.group(1)}/${pkg.group(2)}'
        : uri.startsWith('dart:') || lib < 0
        ? uri.substring(uri.lastIndexOf('/') + 1)
        : uri.substring(lib + 5);
    frames.add({
      'filename': clipUtf8(uri.startsWith('dart:') ? uri : file, 300),
      'package': ?pkg?.group(1),
      'function': clipUtf8(m.group(1)!, 300),
      if (m.group(3) != null) 'lineno': int.parse(m.group(3)!),
      if (m.group(4) != null) 'colno': int.parse(m.group(4)!),
      'abs_path': clipUtf8(uri, 400),
      'in_app':
          !uri.startsWith('dart:') &&
          !uri.startsWith('package:flutter/') &&
          !uri.startsWith('package:yingyeothon_tracer_'),
      'platform': 'dart',
    });
    if (frames.length == 200) break;
  }
  return frames.reversed.toList();
}
