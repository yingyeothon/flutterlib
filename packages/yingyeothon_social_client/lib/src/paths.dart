import 'rules.dart';

/// Builds every URL the client requests. Each segment is checked against the
/// server's grammar first, so nothing that reaches a path needs encoding and
/// a query value is the only thing `Uri` escapes.
abstract final class SocialPaths {
  /// `/social/me/profile`.
  static const List<String> myProfile = <String>['social', 'me', 'profile'];

  /// `/social/profiles`.
  static const List<String> profiles = <String>['social', 'profiles'];

  /// `/social/friends`.
  static const List<String> friends = <String>['social', 'friends'];

  /// `/social/requests`.
  static const List<String> requests = <String>['social', 'requests'];

  /// `/social/blocks`.
  static const List<String> blocks = <String>['social', 'blocks'];

  /// `/social/requests/{player}/accept` or `/decline`.
  static List<String> requestAction(String player, String action) => <String>[
    ...requests,
    SocialRules.checkPlayerId(player),
    action,
  ];

  /// `/social/requests/{player}`.
  static List<String> request(String player) => <String>[
    ...requests,
    SocialRules.checkPlayerId(player),
  ];

  /// `/social/friends/{player}`.
  static List<String> friend(String player) => <String>[
    ...friends,
    SocialRules.checkPlayerId(player),
  ];

  /// `/social/blocks/{player}`.
  static List<String> block(String player) => <String>[
    ...blocks,
    SocialRules.checkPlayerId(player),
  ];

  /// `/social/u/{owner}/friends`.
  static List<String> friendsOf(String player) => <String>[
    'social',
    'u',
    SocialRules.checkPlayerId(player),
    'friends',
  ];

  /// `/social/u/{owner}/profile`; the owner may be a guild.
  static List<String> profileOf(String owner) => <String>[
    'social',
    'u',
    SocialRules.checkProfileOwner(owner),
    'profile',
  ];

  /// `/social/u/{owner}/relations[/{other}]`.
  static List<String> relationsOf(String player, String? other) => <String>[
    'social',
    'u',
    SocialRules.checkPlayerId(player),
    'relations',
    if (other != null) SocialRules.checkPlayerId(other),
  ];

  /// `ids=a,b,c`.
  static Map<String, String> idsQuery(Iterable<String> ids) => <String, String>{
    'ids': SocialRules.checkProfileIds(ids).join(','),
  };

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
