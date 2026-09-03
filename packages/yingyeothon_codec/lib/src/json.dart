import 'dart:convert' as convert;

/// A decoded JSON object. Keys are wire field names.
typedef JsonObject = Map<String, Object?>;

/// A decoded JSON array.
typedef JsonList = List<Object?>;

/// Why a text was refused. Only three kinds: `dart:convert` does not expose a
/// finer grammar error, and a finer one would have to quote the input to be
/// useful, which a failure must never do.
enum JsonParseError {
  /// Longer than the cap. Checked before a single character is parsed.
  inputTooLong,

  /// Nested deeper than [Json.maxDepth].
  depthExceeded,

  /// Not JSON. [JsonParseFailure.offset] says where the parser gave up.
  malformed,
}

/// A refusal: a code and an offset, and nothing derived from the input.
///
/// `FormatException.toString()` quotes a window of the text it failed on; a
/// frame body or a map asset must not reach a log that way, so this type is
/// the only thing the decoder reports.
final class JsonParseFailure {
  /// Creates a failure. [offset] is `-1` when the parser gave none.
  const JsonParseFailure(this.error, this.offset);

  /// What went wrong.
  final JsonParseError error;

  /// Character offset into the input, or `-1`.
  final int offset;

  /// `"<error> at <offset>"`. Tests assert equality with this template to
  /// prove nothing from the input leaks through.
  @override
  String toString() => '${error.name} at $offset';
}

/// Result of [Json.tryDecode]: either [JsonDecoded] or [JsonRefused].
sealed class JsonDecodeResult {
  const JsonDecodeResult();
}

/// The text was JSON; [value] is what it decoded to (possibly `null`).
final class JsonDecoded extends JsonDecodeResult {
  /// Wraps a decoded value.
  const JsonDecoded(this.value);

  /// The decoded value: a [JsonObject], [JsonList], `String`, `num`, `bool`
  /// or `null`.
  final Object? value;
}

/// The text was refused; [failure] says why.
final class JsonRefused extends JsonDecodeResult {
  /// Wraps a refusal.
  const JsonRefused(this.failure);

  /// The code and offset.
  final JsonParseFailure failure;
}

/// Thrown by [Json.decode]. Carries a [JsonParseFailure], never the input.
final class JsonParseException implements Exception {
  /// Wraps a refusal.
  const JsonParseException(this.failure);

  /// The code and offset.
  final JsonParseFailure failure;

  @override
  String toString() => 'JsonParseException: $failure';
}

/// Thrown by [Json.encode] when a value nests deeper than [Json.maxDepth].
final class JsonDepthError extends Error {
  /// The depth cap that was exceeded.
  final int maxDepth = Json.maxDepth;

  @override
  String toString() => 'JsonDepthError: value nests deeper than $maxDepth';
}

/// Thrown by [Json.encode] when a value cannot be represented (a `NaN`, an
/// object of an unsupported type). The message names the kind, not the value.
final class JsonEncodeError extends Error {
  /// Creates an error naming the unsupported kind.
  JsonEncodeError(this.kind);

  /// The runtime type name of the value that could not be encoded.
  final String kind;

  @override
  String toString() => 'JsonEncodeError: cannot encode a value of kind $kind';
}

/// Bounded JSON entry points.
abstract final class Json {
  /// Cap for [tryDecode]: 1 MiB of characters. Every gateway frame is far
  /// below the gateway's own 32 KiB outbound cap; anything larger is not a
  /// frame.
  static const int maxLength = 1 << 20;

  /// Cap for [tryDecodeBig]: 64 MiB, for a map asset.
  static const int maxBigLength = 64 << 20;

  /// Maximum nesting of arrays and objects, on both decode and encode.
  static const int maxDepth = 64;

  /// Decodes a frame-sized text without throwing.
  static JsonDecodeResult tryDecode(String text) => _tryDecode(text, maxLength);

  /// Decodes a large text (a map asset) without throwing. [maxLength] may be
  /// lowered but not raised above [maxBigLength].
  static JsonDecodeResult tryDecodeBig(
    String text, {
    int maxLength = maxBigLength,
  }) {
    if (maxLength > maxBigLength) {
      throw ArgumentError.value(
        maxLength,
        'maxLength',
        'must be at most Json.maxBigLength',
      );
    }
    return _tryDecode(text, maxLength);
  }

  /// Decodes a frame-sized text, throwing [JsonParseException] on refusal.
  static Object? decode(String text) => switch (tryDecode(text)) {
    JsonDecoded(:final value) => value,
    JsonRefused(:final failure) => throw JsonParseException(failure),
  };

  /// Encodes a value with the depth cap enforced before serialization.
  ///
  /// Throws [JsonDepthError] or [JsonEncodeError]; neither names the value.
  static String encode(Object? value) {
    if (depthOf(value) > maxDepth) {
      throw JsonDepthError();
    }
    try {
      return convert.jsonEncode(value);
    } on convert.JsonUnsupportedObjectError catch (e) {
      throw JsonEncodeError(e.unsupportedObject.runtimeType.toString());
    }
  }

  /// Starts a builder for an object whose absent fields stay absent.
  static JsonObjectBuilder object() => JsonObjectBuilder();

  /// Nesting depth of a decoded value: a scalar is 0, `{}` and `[]` are 1.
  /// Iterative, so a hostile depth cannot overflow the stack here either.
  static int depthOf(Object? value) {
    var deepest = 0;
    final stack = <(Object?, int)>[(value, 0)];
    while (stack.isNotEmpty) {
      final (node, depth) = stack.removeLast();
      if (node is Map) {
        if (depth + 1 > deepest) deepest = depth + 1;
        for (final child in node.values) {
          stack.add((child, depth + 1));
        }
      } else if (node is List) {
        if (depth + 1 > deepest) deepest = depth + 1;
        for (final child in node) {
          stack.add((child, depth + 1));
        }
      }
    }
    return deepest;
  }

  static JsonDecodeResult _tryDecode(String text, int cap) {
    if (text.length > cap) {
      return JsonRefused(JsonParseFailure(JsonParseError.inputTooLong, cap));
    }
    final Object? value;
    try {
      value = convert.jsonDecode(text);
    } on FormatException catch (e) {
      // Only the offset crosses this boundary; e.message and e.source quote
      // the input.
      return JsonRefused(
        JsonParseFailure(JsonParseError.malformed, e.offset ?? -1),
      );
    }
    if (depthOf(value) > maxDepth) {
      return const JsonRefused(
        JsonParseFailure(JsonParseError.depthExceeded, -1),
      );
    }
    return JsonDecoded(value);
  }
}

/// Builds a [JsonObject] where `set(key, null)` omits the key and
/// [setNull] writes an explicit JSON `null`.
///
/// The gateway marshals with Go `omitempty`, so "absent" and "null" are
/// different things on the wire; keeping them apart here is what lets a
/// frame writer say exactly one of them.
final class JsonObjectBuilder {
  final JsonObject _fields = <String, Object?>{};

  /// Sets [key] when [value] is not `null`; otherwise leaves it absent.
  JsonObjectBuilder set(String key, Object? value) {
    if (value == null) {
      _fields.remove(key);
    } else {
      _fields[key] = value;
    }
    return this;
  }

  /// Writes an explicit JSON `null` under [key].
  JsonObjectBuilder setNull(String key) {
    _fields[key] = null;
    return this;
  }

  /// A snapshot; later calls on the builder do not affect it.
  JsonObject build() => Map<String, Object?>.of(_fields);
}

/// Typed readers over a decoded object. A missing key and a key holding the
/// wrong type both read as `null`; [has] tells presence apart from null.
extension JsonReading on JsonObject {
  /// Whether [key] is present, even if its value is JSON `null`.
  bool has(String key) => containsKey(key);

  /// The string under [key], or `null`.
  String? getString(String key) {
    final v = this[key];
    return v is String ? v : null;
  }

  /// The number under [key], or `null`.
  num? getNumber(String key) {
    final v = this[key];
    return v is num ? v : null;
  }

  /// The number under [key] as an `int` (a whole `double` converts), or
  /// `null`.
  int? getInt(String key) {
    final v = this[key];
    if (v is int) return v;
    if (v is double && v.isFinite && v == v.truncateToDouble()) {
      return v.toInt();
    }
    return null;
  }

  /// The number under [key] as a `double`, or `null`.
  double? getDouble(String key) {
    final v = this[key];
    return v is num ? v.toDouble() : null;
  }

  /// The bool under [key], or `null`.
  bool? getBool(String key) {
    final v = this[key];
    return v is bool ? v : null;
  }

  /// The object under [key], or `null`.
  JsonObject? getObject(String key) {
    final v = this[key];
    return v is Map<String, Object?> ? v : null;
  }

  /// The list under [key], or an empty list when absent, null or not a list.
  JsonList getListOrEmpty(String key) {
    final v = this[key];
    return v is List<Object?> ? v : const <Object?>[];
  }
}
