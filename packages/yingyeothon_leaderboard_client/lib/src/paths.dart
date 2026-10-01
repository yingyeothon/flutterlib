import 'rules.dart';

/// Builds every URL the client requests. Each segment is checked against the
/// server's grammar first, so nothing that reaches a path needs encoding and
/// a query value is the only thing `Uri` escapes.
abstract final class LbPaths {
  /// `/lb/{board}`.
  static List<String> board(String ref) => <String>[
    'lb',
    LbRules.checkBoardRef(ref),
  ];

  /// `/lb/{board}/scores/{owner}`.
  static List<String> score(String ref, String owner) => <String>[
    ...board(ref),
    'scores',
    LbRules.checkOwner(owner),
  ];

  /// `/lb/{board}/top`.
  static List<String> top(String ref) => <String>[...board(ref), 'top'];

  /// `/lb/{board}/periods/{period}`; the period is checked to be a name.
  static List<String> period(String ref, String period) => <String>[
    ...board(ref),
    'periods',
    LbRules.checkPeriod(period)!,
  ];

  /// `period=`, `limit=`, `offset=`; only what is set.
  static Map<String, String> topQuery({
    String? period,
    int? limit,
    int? offset,
  }) {
    final checkedPeriod = LbRules.checkPeriod(period);
    final checkedLimit = LbRules.checkLimit(limit);
    final checkedOffset = LbRules.checkOffset(offset);
    return <String, String>{
      'period': ?checkedPeriod,
      if (checkedLimit != null) 'limit': '$checkedLimit',
      if (checkedOffset != null) 'offset': '$checkedOffset',
    };
  }

  /// `period=` or nothing.
  static Map<String, String> periodQuery(String? period) {
    final checked = LbRules.checkPeriod(period);
    return <String, String>{'period': ?checked};
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
