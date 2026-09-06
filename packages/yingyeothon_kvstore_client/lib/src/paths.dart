import 'rules.dart';
import 'types.dart';

/// Builds every URL the client requests. Each segment is checked against the
/// server's grammar first, so nothing that reaches a path needs encoding and
/// a query value is the only thing `Uri` escapes.
abstract final class KvPaths {
  /// `/kv/{col}`.
  static List<String> collection(String ref) => <String>[
    'kv',
    KvRules.checkCollectionRef(ref),
  ];

  /// `/kv/{col}/entries` or `/kv/{col}/u/{owner}/entries`.
  static List<String> entries(String ref, String? owner) => <String>[
    ...collection(ref),
    if (owner != null) ...<String>['u', KvRules.checkOwnerId(owner)],
    'entries',
  ];

  /// `…/entries/{key}`.
  static List<String> entry(String ref, String? owner, String key) => <String>[
    ...entries(ref, owner),
    KvRules.checkKey(key),
  ];

  /// `prefix`, `cursor`, `limit`, `order=desc`, `values=1`; only what is set.
  static Map<String, String> listQuery({
    String? prefix,
    String? cursor,
    int? limit,
    KvOrder order = KvOrder.asc,
    bool values = false,
  }) {
    final checkedLimit = KvRules.checkLimit(limit);
    return <String, String>{
      'prefix': ?prefix,
      'cursor': ?cursor,
      if (checkedLimit != null) 'limit': '$checkedLimit',
      if (order == KvOrder.desc) 'order': 'desc',
      if (values) 'values': '1',
    };
  }

  /// `ttl=` or nothing.
  static Map<String, String> ttlQuery(int? ttl) {
    final checked = KvRules.checkTtl(ttl);
    return <String, String>{if (checked != null) 'ttl': '$checked'};
  }

  /// [base] with [segments] appended to its path and [query] as the query.
  /// A base URL with a path keeps it; a trailing slash is not doubled.
  static Uri resolve(
    Uri base,
    List<String> segments,
    Map<String, String> query,
  ) => Uri(
    scheme: base.scheme,
    userInfo: base.userInfo.isEmpty ? null : base.userInfo,
    host: base.host,
    port: base.hasPort ? base.port : null,
    pathSegments: <String>[
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ...segments,
    ],
    queryParameters: query.isEmpty ? null : query,
  );
}
