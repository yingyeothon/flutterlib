import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// The one exception the client throws for anything the server, or the
/// network, refused. Local refusals (grammar, size, ranges) are plain
/// [ArgumentError]s thrown before any request is made.
///
/// Carries a status and a code, never a key, a value, a URL or the token.
final class KvStoreException implements Exception {
  /// Creates an exception.
  const KvStoreException(
    this.status,
    this.code, {
    this.reason,
    this.currentVersion,
    this.hasCurrentVersion = false,
  });

  /// The request never got an answer: timeout or network error.
  static const String networkCode = 'network';

  /// The server promised JSON and sent something else, an `ETag` that is
  /// not a version, or a body over the 4 MiB cap; [status] is the answer's.
  static const String malformedResponseCode = 'malformed_response';

  /// A `404` on a `get` without `orElse`.
  static const String notFoundCode = 'not_found';

  /// HTTP status; `0` when the request never got an answer.
  final int status;

  /// The server's `error.code` when it matches `^[a-z][a-z0-9_]{0,63}$`, or
  /// `http_<status>` when the body carried none (or one outside that
  /// grammar), or [networkCode] / [malformedResponseCode].
  final String code;

  /// `error.details.reason` when the server named one: `collection_full`,
  /// `owner_full`, `not_a_number`, `overflow`, `wrong_namespace`, and on a
  /// `503` `kv_encryption_not_configured` or `kv_value_unreadable`.
  final String? reason;

  /// On a lost compare-and-set, the live version; `null` with
  /// [hasCurrentVersion] when the key is absent. Only a caller with the read
  /// right is told.
  final int? currentVersion;

  /// Whether the server sent `details.current` at all.
  final bool hasCurrentVersion;

  /// `409`: a lost compare-and-set, a full collection or owner, or an `incr`
  /// on a non-number.
  bool get isConflict => status == 409;

  /// `403`: the scope refuses this principal, or a conditional write without
  /// the read right.
  bool get isForbidden => status == 403;

  /// `401`: the token is missing, expired or not for this stage.
  bool get isUnauthorized => status == 401;

  /// `409` for a lost compare-and-set alone: a `409` without a `reason`.
  /// [currentVersion] is filled only for a caller with the read right.
  bool get isVersionMismatch => isConflict && reason == null;

  /// `409` with `details.reason` `collection_full` or `owner_full`.
  bool get isFull =>
      isConflict && (reason == 'collection_full' || reason == 'owner_full');

  /// `404`: no such collection in the caller's project, or no such key.
  bool get isNotFound => status == 404;

  /// Builds the exception from a refused response. The body is read for its
  /// `code`, `details.reason` and `details.current` only.
  factory KvStoreException.fromResponse(int status, String body) {
    final decoded = Json.tryDecode(body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    final error = value is JsonObject ? value.getObject('error') : null;
    final details = error?.getObject('details');
    final current = details?['current'];
    final hasCurrent = details?.has('current') ?? false;
    // `code` and `reason` reach `toString()` and log lines, so a value the
    // server (or whatever answered in its place) chose outside the code
    // grammar is dropped rather than carried.
    final code = error?.getString('code');
    final reason = details?.getString('reason');
    return KvStoreException(
      status,
      code != null && _codePattern.hasMatch(code) ? code : 'http_$status',
      reason: reason != null && _codePattern.hasMatch(reason) ? reason : null,
      currentVersion: current is int ? current : null,
      hasCurrentVersion: hasCurrent && (current == null || current is int),
    );
  }

  static final RegExp _codePattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  /// `"3"`, `W/"3"` and `3` all read as `3`; anything else is `null`.
  static int? parseEtagVersion(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^(?:W/)?(?:"(\d{1,15})"|(\d{1,15}))$')
        .firstMatch(raw.trim());
    if (match == null) return null;
    return int.parse(match.group(1) ?? match.group(2)!);
  }

  /// `X-KV-Expires-At` is an absolute epoch second; anything else is `null`.
  static int? parseExpiresAt(String? raw) {
    if (raw == null) return null;
    final value = int.tryParse(raw.trim());
    return value != null && value > 0 ? value : null;
  }

  /// Deliberately the code and the status only.
  @override
  String toString() => 'KvStoreException($code, $status)';
}
