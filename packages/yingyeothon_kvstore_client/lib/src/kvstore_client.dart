import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'internal/client_impl.dart';
import 'types.dart';

/// Options for a [KvStoreClient]. Immutable; a new token is a new client.
final class KvStoreClientOptions {
  /// Creates options.
  const KvStoreClientOptions({
    required this.baseUrl,
    required this.token,
    this.client,
    this.logger,
    this.timeout,
  });

  /// `https://doc.yyt.life` or `https://doc-dev.yyt.life`; no default. A
  /// path is kept and the `/kv/…` routes are appended to it.
  final Uri baseUrl;

  /// The channel JWT (a player) or the auth channel's doc apiKey (the game's
  /// server). Sent as `Authorization: Bearer` and never logged.
  final String token;

  /// The HTTP client to send with; `null` creates one the library owns and
  /// [KvStoreClient.close] closes. An injected client is never closed here.
  final http.Client? client;

  /// Receives `kv request` lines with the method, the route kind, the status
  /// and the body length; `null` is [nullLogger].
  final Logger? logger;

  /// One deadline for headers and body; `null` is 15 seconds.
  final Duration? timeout;
}

/// A client for the yyt key-value store, speaking for one credential.
abstract interface class KvStoreClient {
  /// Creates a client. Throws [ArgumentError] when [KvStoreClientOptions.baseUrl]
  /// is not a bare absolute `http(s)` URL (no user info, query or fragment)
  /// or the token is empty or has a character outside printable ASCII; the
  /// message names an index, never the character.
  factory KvStoreClient(KvStoreClientOptions options) = KvStoreClientImpl;

  /// Addresses a collection by its `kv_…` id or by its console name, resolved
  /// by the server within the caller's project. Pure: it builds paths and
  /// holds no state. Throws [ArgumentError] for a segment outside both
  /// grammars.
  KvCollection collection(String nameOrId);

  /// Closes the HTTP client this library created; an injected one is left
  /// to its owner. Idempotent. A request after `close()` on an owned client
  /// fails as a [KvStoreException] with [KvStoreException.networkCode].
  void close();
}

/// A collection: its shared namespace, its shape, and its owner namespaces.
abstract interface class KvCollection implements KvNamespace {
  /// What was passed to [KvStoreClient.collection].
  String get ref;

  /// `GET /kv/{col}`: scopes, `encrypted`, both caps. `403` when both scopes
  /// are `team`.
  Future<KvCollectionInfo> info();

  /// The caller's own user namespace, `/kv/{col}/u/me/entries`.
  KvNamespace get mine;

  /// Another owner's user namespace, `/kv/{col}/u/{ownerId}/entries`; the
  /// server key may write any of them. Throws [ArgumentError] for an owner id
  /// outside the server's grammar.
  KvNamespace owner(String ownerId);
}

/// The six operations, on the shared namespace or on one owner's.
abstract interface class KvNamespace {
  /// The stored value, decoded. A stored JSON `null` is `null`; a missing key
  /// calls [orElse] when given and throws [KvStoreException] with
  /// [KvStoreException.notFoundCode] otherwise. `orElse: () => null` is the
  /// "treat missing as null" idiom.
  Future<Object?> get(String key, {Object? Function()? orElse});

  /// The value with its version and expiry, or `null` for a missing key.
  Future<KvEntry?> getEntry(String key);

  /// Stores [value] as JSON. [ttl] is seconds (`0` clears the expiry, omitted
  /// keeps it); [ifMatch] writes only while the stored version is that one;
  /// [ifNoneMatch] writes only while the key is absent. The two together, a
  /// value over 16 KiB and a ttl out of range are [ArgumentError]s.
  Future<KvWriteResult> put(
    String key,
    Object? value, {
    int? ttl,
    int? ifMatch,
    bool ifNoneMatch = false,
  });

  /// Deletes [key]; a missing key is not an error (the server's `404` for a
  /// reader is folded into success). [ifMatch] deletes only while the stored
  /// version is that one; a mismatch is a `409`, and a missing key under
  /// [ifMatch] is also a `404`, folded the same way.
  Future<void> delete(String key, {int? ifMatch});

  /// One page of keys, optionally with values. [limit] is 1 … 100 (server
  /// default 50); [cursor] is the previous page's `nextCursor`.
  Future<KvPage> list({
    String? prefix,
    String? cursor,
    int? limit,
    KvOrder order = KvOrder.asc,
    bool values = false,
  });

  /// Atomic `{"incr": delta}` on a numeric value; a missing key starts at
  /// zero. Needs the read right.
  Future<KvIncrResult> incr(String key, int delta, {int? ttl});
}
