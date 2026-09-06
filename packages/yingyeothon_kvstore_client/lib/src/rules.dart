import 'dart:convert';

/// The server's rules the client refuses locally, and nothing more.
///
/// Every constant is a copy of one in the `service` repository
/// (`packages/console-db/src/kvstore.ts`); when that file changes, this one
/// follows. A local refusal is a fast `ArgumentError` whose message names the
/// rule and never the input; the server is the enforcement.
abstract final class KvRules {
  /// `KV_KEY_RE`: what a key may look like.
  static final RegExp keyPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
  );

  /// The console's collection name grammar (`checkKvName`).
  static final RegExp collectionNamePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
  );

  /// `KV_COLLECTION_ID_RE`: a `kv_` id goes on the path as is.
  static final RegExp collectionIdPattern = RegExp(r'^kv_[0-9a-z]{26}$');

  /// `KV_OWNER_ID` plus the player alias `me`.
  static final RegExp ownerIdPattern = RegExp(
    r'^(?:me|[0-9a-f]{32}|[a-z]{1,8}:[A-Za-z0-9_-]{1,48})$',
  );

  /// `MAX_KV_VALUE_BYTES`: the largest value, in UTF-8 bytes as sent.
  static const int maxValueBytes = 16 * 1024;

  /// `KV_TTL_MIN_SECONDS`.
  static const int ttlMinSeconds = 1;

  /// `KV_TTL_MAX_SECONDS`: 366 days, so "a year" is always expressible.
  static const int ttlMaxSeconds = 366 * 24 * 60 * 60;

  /// `KV_LIST_LIMIT_MAX`; the minimum is 1 and the server default 50.
  static const int listLimitMax = 100;

  /// The alias the server resolves to the token's own user id.
  static const String selfOwner = 'me';

  /// UTF-8 byte length, which is what the server measures.
  static int valueBytes(String text) => utf8.encode(text).length;

  /// Returns [ref] when it is a `kv_` id or a name the console could have
  /// accepted; throws otherwise. The edge is not transparent to encoded
  /// segments, so nothing outside both grammars is ever encoded.
  static String checkCollectionRef(String ref) {
    if (collectionIdPattern.hasMatch(ref) ||
        collectionNamePattern.hasMatch(ref)) {
      return ref;
    }
    throw ArgumentError(
      'kv collection must be a kv_ id or a name matching '
      '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\$',
    );
  }

  /// Returns [key] when it matches [keyPattern]; throws otherwise.
  static String checkKey(String key) {
    if (keyPattern.hasMatch(key)) return key;
    throw ArgumentError(
      'kv key must match ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\$',
    );
  }

  /// Returns [ownerId] when it is `me`, 32 hex characters or `{kind}:{id}`;
  /// throws otherwise.
  static String checkOwnerId(String ownerId) {
    if (ownerIdPattern.hasMatch(ownerId)) return ownerId;
    throw ArgumentError('kv owner must be me, 32 hex characters, or kind:id');
  }

  /// Returns [ttl] when it is `null`, `0` (clear) or within the bounds;
  /// throws otherwise.
  static int? checkTtl(int? ttl) {
    if (ttl == null || ttl == 0) return ttl;
    if (ttl >= ttlMinSeconds && ttl <= ttlMaxSeconds) return ttl;
    throw ArgumentError(
      'kv ttl must be 0 or between $ttlMinSeconds and $ttlMaxSeconds seconds',
    );
  }

  /// Returns [limit] when it is `null` or 1 … [listLimitMax]; throws
  /// otherwise.
  static int? checkLimit(int? limit) {
    if (limit == null) return null;
    if (limit >= 1 && limit <= listLimitMax) return limit;
    throw ArgumentError('kv list limit must be between 1 and $listLimitMax');
  }

  /// Returns [version] when it is at least 1; throws otherwise. There is no
  /// version 0: the server refuses `If-Match: 0` ("use If-None-Match: * to
  /// create").
  static int checkVersion(int version, String name) {
    if (version >= 1) return version;
    throw ArgumentError('kv $name must be a version of 1 or more');
  }

  /// Returns [text] when it fits [maxValueBytes]; throws otherwise. The
  /// message carries the cap, never the value or its length.
  static String checkValueText(String text) {
    if (valueBytes(text) <= maxValueBytes) return text;
    throw ArgumentError('kv value exceeds $maxValueBytes bytes');
  }
}
