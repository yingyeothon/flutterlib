import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import '../errors.dart';
import '../kvstore_client.dart';
import '../paths.dart';
import '../rules.dart';
import '../types.dart';
import 'requester.dart';

/// The six operations over one `…/entries` path.
class KvNamespaceImpl implements KvNamespace {
  /// Creates a namespace over [ref] for [ownerId] (`null` = shared).
  KvNamespaceImpl(this.requester, this.ref, this.ownerId)
    // Checked once here, so a bad collection or owner throws at
    // `collection()` / `owner()` time rather than on the first call.
    : entries = KvPaths.entries(ref, ownerId);

  /// The shared request choke point.
  final KvRequester requester;

  /// What was passed to `collection()`.
  final String ref;

  /// The owner segment, or `null` for the shared namespace.
  final String? ownerId;

  /// The checked `…/entries` path.
  final List<String> entries;

  static const KvStoreException _malformed = KvStoreException(
    200,
    KvStoreException.malformedResponseCode,
  );

  /// Decodes a body the server promised would be JSON.
  static Object? _decode(String text) {
    final decoded = Json.tryDecodeBig(
      text,
      maxLength: KvRequester.maxResponseBytes,
    );
    if (decoded is! JsonDecoded) throw _malformed;
    return decoded.value;
  }

  static Map<String, String> _conditions({
    int? ifMatch,
    bool ifNoneMatch = false,
  }) {
    if (ifMatch != null && ifNoneMatch) {
      throw ArgumentError('kv ifMatch and ifNoneMatch cannot be combined');
    }
    return <String, String>{
      if (ifMatch != null)
        'if-match': '"${KvRules.checkVersion(ifMatch, 'ifMatch')}"',
      if (ifNoneMatch) 'if-none-match': '*',
    };
  }

  @override
  Future<Object?> get(String key, {Object? Function()? orElse}) async {
    final entry = await getEntry(key);
    if (entry != null) return entry.value;
    if (orElse != null) return orElse();
    throw const KvStoreException(404, KvStoreException.notFoundCode);
  }

  @override
  Future<KvEntry?> getEntry(String key) async {
    final path = KvPaths.entry(ref, ownerId, key);
    final KvAnswer answer;
    try {
      answer = await requester.send('GET', KvRoute.entry, path);
    } on KvStoreException catch (e) {
      // A missing entry is the one refusal that is an answer, and only here.
      if (e.status == 404) return null;
      rethrow;
    }
    final version = answer.version;
    if (version == null) throw _malformed;
    return KvEntry(
      value: _decode(answer.body),
      version: version,
      expiresAt: answer.expiresAt,
    );
  }

  @override
  Future<KvWriteResult> put(
    String key,
    Object? value, {
    int? ttl,
    int? ifMatch,
    bool ifNoneMatch = false,
  }) async {
    final path = KvPaths.entry(ref, ownerId, key);
    final headers = _conditions(ifMatch: ifMatch, ifNoneMatch: ifNoneMatch);
    final body = KvRules.checkValueText(Json.encode(value));
    final answer = await requester.send(
      'PUT',
      KvRoute.entry,
      path,
      query: KvPaths.ttlQuery(ttl),
      headers: headers,
      body: body,
    );
    // 201 and the ETag are both facts about stored data, and a write-only
    // caller is told neither: it always sees 204 and no ETag.
    final version = answer.version;
    return KvWriteResult(
      created: version == null ? null : answer.status == 201,
      version: version,
      expiresAt: answer.expiresAt,
    );
  }

  @override
  Future<void> delete(String key, {int? ifMatch}) async {
    final path = KvPaths.entry(ref, ownerId, key);
    try {
      await requester.send(
        'DELETE',
        KvRoute.entry,
        path,
        headers: _conditions(ifMatch: ifMatch),
      );
    } on KvStoreException catch (e) {
      // A reader is told 404 for a key that was not there; a write-only
      // caller gets 204 either way. Neither is an error to the caller of
      // `delete`, so both read as done.
      if (e.status == 404) return;
      rethrow;
    }
  }

  @override
  Future<KvPage> list({
    String? prefix,
    String? cursor,
    int? limit,
    KvOrder order = KvOrder.asc,
    bool values = false,
  }) async {
    final answer = await requester.send(
      'GET',
      KvRoute.entries,
      entries,
      query: KvPaths.listQuery(
        prefix: prefix,
        cursor: cursor,
        limit: limit,
        order: order,
        values: values,
      ),
    );
    final page = _decode(answer.body);
    if (page is! JsonObject) throw _malformed;
    final rows = <KvListEntry>[];
    for (final row in page.getListOrEmpty('entries')) {
      if (row is! JsonObject) throw _malformed;
      final key = row.getString('key');
      final version = row.getInt('version');
      if (key == null || version == null) throw _malformed;
      final valueText = row.getString('valueText');
      rows.add(
        KvListEntry(
          owner: row.getString('owner'),
          key: key,
          version: version,
          bytes: row.getInt('bytes') ?? 0,
          expiresAt: row.getInt('expiresAt'),
          updatedAt: row.getInt('updatedAt') ?? 0,
          hasValue: valueText != null,
          value: valueText == null ? null : _decode(valueText),
          raw: row,
        ),
      );
    }
    return KvPage(
      entries: List<KvListEntry>.unmodifiable(rows),
      nextCursor: page.getString('nextCursor'),
    );
  }

  @override
  Future<KvIncrResult> incr(String key, int delta, {int? ttl}) async {
    final path = KvPaths.entry(ref, ownerId, key);
    final answer = await requester.send(
      'PATCH',
      KvRoute.incr,
      path,
      query: KvPaths.ttlQuery(ttl),
      body: Json.encode(<String, Object?>{'incr': delta}),
    );
    final result = _decode(answer.body);
    if (result is! JsonObject) throw _malformed;
    final value = result.getInt('value');
    final version = result.getInt('version');
    if (value == null || version == null) throw _malformed;
    return KvIncrResult(value: value, version: version);
  }
}
