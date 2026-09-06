import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// The scopes a collection's `readScope` and `writeScope` take. An open
/// string set, not an enum, so a scope the console adds later cannot become
/// a parse failure.
abstract final class KvScope {
  /// Console and CLI only; the API answers `403`.
  static const String team = 'team';

  /// Any credential of the collection's project.
  static const String project = 'project';

  /// The server key on anyone's behalf; a player on its own entries.
  static const String user = 'user';
}

/// Listing order by key.
enum KvOrder {
  /// Ascending, the server default.
  asc,

  /// Descending.
  desc,
}

/// The collection's shape from `GET /kv/{col}`.
final class KvCollectionInfo {
  /// Creates an info.
  const KvCollectionInfo({
    required this.id,
    required this.name,
    required this.readScope,
    required this.writeScope,
    required this.encrypted,
    required this.maxEntries,
    required this.maxEntriesPerOwner,
    required this.raw,
  });

  /// Reads the object. A missing string reads as empty, a missing number as
  /// `0`, a missing flag as `false`.
  factory KvCollectionInfo.fromJson(JsonObject json) => KvCollectionInfo(
    id: json.getString('id') ?? '',
    name: json.getString('name') ?? '',
    readScope: json.getString('readScope') ?? '',
    writeScope: json.getString('writeScope') ?? '',
    encrypted: json.getBool('encrypted') ?? false,
    maxEntries: json.getInt('maxEntries') ?? 0,
    maxEntriesPerOwner: json.getInt('maxEntriesPerOwner') ?? 0,
    raw: json,
  );

  /// The `kv_` id.
  final String id;

  /// The console name.
  final String name;

  /// Who may read: a [KvScope] value.
  final String readScope;

  /// Who may write: a [KvScope] value. `user` puts every entry in an owner
  /// namespace.
  final String writeScope;

  /// Whether values are stored encrypted.
  final bool encrypted;

  /// Entries the collection may hold.
  final int maxEntries;

  /// Entries one owner may hold.
  final int maxEntriesPerOwner;

  /// Whether `writeScope` is `user`, which is what puts every entry under
  /// `/u/{ownerId}` (the `mine` and `owner()` namespaces) rather than the
  /// shared `entries` path.
  bool get isUserNamespace => writeScope == KvScope.user;

  /// The object as received.
  final JsonObject raw;
}

/// One stored entry with its version and expiry.
final class KvEntry {
  /// Creates an entry.
  const KvEntry({required this.value, required this.version, this.expiresAt});

  /// The stored JSON value, decoded. A stored `null` is `null` here.
  final Object? value;

  /// The version from `ETag`; monotonic per key.
  final int version;

  /// Absolute epoch second from `X-KV-Expires-At`; `null` when the entry never
  /// expires.
  final int? expiresAt;
}

/// What a `put` learned. [created] and [version] are `null` for a caller
/// without the read right: a write-only caller is told neither `201` nor the
/// version. [expiresAt] still comes back whenever that write set a `ttl`.
final class KvWriteResult {
  /// Creates a result.
  const KvWriteResult({this.created, this.version, this.expiresAt});

  /// Whether the key was created (`201`) rather than updated (`204`).
  final bool? created;

  /// The new version, from `ETag`.
  final int? version;

  /// Absolute epoch second, present only when this write set the expiry.
  final int? expiresAt;
}

/// One row of a listing.
final class KvListEntry {
  /// Creates a row.
  const KvListEntry({
    required this.key,
    required this.version,
    required this.bytes,
    required this.updatedAt,
    required this.hasValue,
    this.owner,
    this.expiresAt,
    this.value,
    required this.raw,
  });

  /// The owner, present only in a user namespace.
  final String? owner;

  /// The key.
  final String key;

  /// The version.
  final int version;

  /// Plaintext byte length of the value.
  final int bytes;

  /// Absolute epoch second, or `null`.
  final int? expiresAt;

  /// Epoch second of the last write.
  final int updatedAt;

  /// Whether the server sent the value (`values: true`); a stored `null`
  /// then reads as `null` with [hasValue] `true`.
  final bool hasValue;

  /// The decoded value when [hasValue].
  final Object? value;

  /// The row as received (`valueText` verbatim).
  final JsonObject raw;
}

/// A page of a listing.
final class KvPage {
  /// Creates a page.
  const KvPage({required this.entries, this.nextCursor});

  /// The rows.
  final List<KvListEntry> entries;

  /// Pass to `list(cursor:)` for the next page; `null` on the last.
  final String? nextCursor;
}

/// What `incr` produced.
final class KvIncrResult {
  /// Creates a result.
  const KvIncrResult({required this.value, required this.version});

  /// The value after the increment.
  final int value;

  /// The version after the increment.
  final int version;
}
