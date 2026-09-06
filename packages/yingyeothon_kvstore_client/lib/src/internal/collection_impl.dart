import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import '../errors.dart';
import '../kvstore_client.dart';
import '../paths.dart';
import '../rules.dart';
import '../types.dart';
import 'namespace_impl.dart';
import 'requester.dart';

/// A collection: the shared namespace plus `info()`, `mine` and `owner()`.
final class KvCollectionImpl extends KvNamespaceImpl implements KvCollection {
  /// Creates a collection over [ref].
  KvCollectionImpl(KvRequester requester, String ref)
    : super(requester, ref, null);

  @override
  Future<KvCollectionInfo> info() async {
    final answer = await requester.send(
      'GET',
      KvRoute.meta,
      KvPaths.collection(ref),
    );
    final decoded = Json.tryDecode(answer.body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    if (value is! JsonObject) {
      throw const KvStoreException(200, KvStoreException.malformedResponseCode);
    }
    return KvCollectionInfo.fromJson(value);
  }

  @override
  late final KvNamespace mine = KvNamespaceImpl(
    requester,
    ref,
    KvRules.selfOwner,
  );

  @override
  KvNamespace owner(String ownerId) => KvNamespaceImpl(requester, ref, ownerId);
}
