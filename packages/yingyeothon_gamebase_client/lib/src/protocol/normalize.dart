/// Wire-shape normalisation shared by the frame parsers.
abstract final class Normalize {
  /// Folds an absent and an empty identifier into `null`. Go marshals an
  /// empty string either as `""` or, with `omitempty`, not at all, and the
  /// gateway uses `partyId: ""` to mean "you are in no party" — the two are
  /// the same fact and a caller must not have to check both.
  static String? optionalId(String? value) =>
      value == null || value.isEmpty ? null : value;

  /// Maximum length of a peer-chosen string in a diagnostic message.
  static const int diagnosticMax = 32;

  /// Renders a peer-chosen string for a diagnostic message. A frame's `type`
  /// is whatever the peer put there, and these messages reach a consumer's
  /// log writer, so it is capped and stripped of control characters before
  /// it can become a log-volume or log-injection vector.
  static String diagnostic(String value) {
    final units = value.codeUnits;
    final length = units.length < diagnosticMax ? units.length : diagnosticMax;
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      final c = units[i];
      buffer.writeCharCode(c < 0x20 || c == 0x7f ? 0x3f : c);
    }
    if (length < units.length) buffer.write('…');
    return buffer.toString();
  }
}
