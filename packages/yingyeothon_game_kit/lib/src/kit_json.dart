import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Interoperable RFC 8785 JSON for deterministic game state and move hashes.
abstract final class KitJson {
  /// Encodes finite IEEE-754 JSON, sorted by UTF-16 keys, without custom serializers.
  static String canonical(Object? value) {
    final seen = HashSet<Object>.identity();
    String encode(Object? v) {
      if (v == null) return 'null';
      if (v is bool) return v ? 'true' : 'false';
      if (v is num) {
        final number = v.toDouble();
        if (!number.isFinite ||
            (v is int && (v < -9007199254740991 || v > 9007199254740991))) {
          throw ArgumentError(
            'kit numbers must be finite IEEE-754 JSON values',
          );
        }
        if (number == 0) return '0';
        final text = number.abs().toString().toLowerCase();
        final parts = text.split('e');
        final mantissa = parts.first;
        var digits = mantissa.replaceAll('.', '');
        var point =
            (mantissa.contains('.') ? mantissa.indexOf('.') : mantissa.length) +
            (parts.length == 2 ? int.parse(parts[1]) : 0);
        while (digits.startsWith('0') && digits.length > 1) {
          digits = digits.substring(1);
          point--;
        }
        while (digits.endsWith('0') && digits.length > 1) {
          digits = digits.substring(0, digits.length - 1);
        }
        final sign = number.isNegative ? '-' : '';
        if (point > 0 && point <= 21) {
          return sign +
              (point >= digits.length
                  ? digits + '0' * (point - digits.length)
                  : '${digits.substring(0, point)}.${digits.substring(point)}');
        }
        if (point <= 0 && point > -6) {
          return '${sign}0.${'0' * (-point)}$digits';
        }
        final exponent = point - 1;
        return '$sign${digits[0]}${digits.length > 1 ? '.${digits.substring(1)}' : ''}e${exponent >= 0 ? '+' : ''}$exponent';
      }
      if (v is String) {
        for (var i = 0; i < v.length; i++) {
          final c = v.codeUnitAt(i);
          if (c >= 0xd800 && c <= 0xdbff) {
            if (++i >= v.length ||
                v.codeUnitAt(i) < 0xdc00 ||
                v.codeUnitAt(i) > 0xdfff) {
              throw ArgumentError('kit strings must be valid Unicode');
            }
          } else if (c >= 0xdc00 && c <= 0xdfff) {
            throw ArgumentError('kit strings must be valid Unicode');
          }
        }
        return jsonEncode(v);
      }
      if (v is! List && v is! Map<String, Object?>) {
        throw ArgumentError('kit values must be plain JSON');
      }
      if (!seen.add(v)) throw ArgumentError('kit JSON cannot contain cycles');
      try {
        if (v is List) return '[${v.map(encode).join(',')}]';
        final object = v as Map<String, Object?>;
        final keys = object.keys.toList()..sort();
        return '{${keys.map((key) => '${encode(key)}:${encode(object[key])}').join(',')}}';
      } finally {
        seen.remove(v);
      }
    }

    return encode(value);
  }

  /// Returns a detached JSON copy for retaining state without caller mutation.
  static Object? copy(Object? value) => jsonDecode(canonical(value));

  /// Hashes canonical UTF-8 JSON as lowercase SHA-256.
  static String hash(Object? value) =>
      sha256.convert(utf8.encode(canonical(value))).toString();

  /// Full UTF-8 canonical JSON size, for room envelopes and log chunks.
  static int bytes(Object? value) => utf8.encode(canonical(value)).length;
}
