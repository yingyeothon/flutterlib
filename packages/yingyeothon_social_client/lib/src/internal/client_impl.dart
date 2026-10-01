import 'package:http/http.dart' as http;
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../errors.dart';
import '../paths.dart';
import '../rules.dart';
import '../social_client.dart';
import '../types.dart';
import 'requester.dart';

/// The client: one requester, the player's routes and the server's.
final class SocialClientImpl implements SocialClient {
  /// Creates the client; a `null` `client` option is one this owns.
  SocialClientImpl(SocialClientOptions options)
    : _requester = SocialRequester(
        // Named arguments are evaluated in source order: the checks come
        // before the client is created, so a refused option leaks none.
        baseUrl: _checkBaseUrl(options.baseUrl),
        token: _checkToken(options.token),
        client: options.client ?? http.Client(),
        ownsClient: options.client == null,
        logger: options.logger ?? nullLogger,
        timeout: options.timeout ?? defaultTimeout,
      );

  /// The deadline when `SocialClientOptions.timeout` is `null`.
  static const Duration defaultTimeout = Duration(seconds: 15);

  final SocialRequester _requester;

  static Uri _checkBaseUrl(Uri url) {
    if ((url.scheme == 'https' || url.scheme == 'http') &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty &&
        !url.hasQuery &&
        !url.hasFragment) {
      return url;
    }
    // Never the URL: dart:io would quote it, and so would we.
    throw ArgumentError(
      'social baseUrl must be an absolute http(s) URL with no user info, '
      'query or fragment',
    );
  }

  /// A bearer token is printable ASCII without spaces. `dart:io` refuses any
  /// other header value with a `FormatException` that quotes the whole
  /// header, so the check happens here, and names the index only.
  static String _checkToken(String token) {
    if (token.isEmpty) throw ArgumentError('social token is required');
    for (var i = 0; i < token.length; i++) {
      final unit = token.codeUnitAt(i);
      if (unit <= 0x20 || unit >= 0x7f) {
        throw ArgumentError(
          'social token has an illegal character at index $i',
        );
      }
    }
    return token;
  }

  static const SocialException _malformed = SocialException(
    200,
    SocialException.malformedResponseCode,
  );

  /// Decodes a body the server promised would be a JSON object.
  static JsonObject _object(SocialAnswer answer) {
    final decoded = Json.tryDecode(answer.body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    if (value is! JsonObject) throw _malformed;
    return value;
  }

  static List<SocialRelation> _relations(JsonObject json, String key) =>
      <SocialRelation>[
        for (final item in json.getListOrEmpty(key))
          if (item is JsonObject) SocialRelation.fromJson(item),
      ];

  static String _profileBody(String displayName, String? avatar) => Json.encode(
    Json.object()
        .set('displayName', SocialRules.checkDisplayName(displayName))
        .set('avatar', SocialRules.checkAvatar(avatar))
        .build(),
  );

  Future<SocialProfileResult> _putProfile(
    List<String> path,
    String displayName,
    String? avatar,
  ) async {
    final body = _profileBody(displayName, avatar);
    final answer = await _requester.send(
      'PUT',
      SocialRoute.profile,
      path,
      body: body,
    );
    return SocialProfileResult(
      profile: SocialProfile.fromJson(_object(answer)),
      created: answer.status == 201,
    );
  }

  Future<bool> _deleteProfile(List<String> path) async {
    try {
      await _requester.send('DELETE', SocialRoute.profile, path);
    } on SocialException catch (e) {
      // No card is the one refusal that is an answer.
      if (e.status == 404) return false;
      rethrow;
    }
    return true;
  }

  Future<void> _done(String method, SocialRoute route, List<String> path) =>
      _requester.send(method, route, path);

  @override
  Future<SocialProfile?> myProfile() async {
    final SocialAnswer answer;
    try {
      answer = await _requester.send(
        'GET',
        SocialRoute.profile,
        SocialPaths.myProfile,
      );
    } on SocialException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
    return SocialProfile.fromJson(_object(answer));
  }

  @override
  Future<SocialProfileResult> putMyProfile(
    String displayName, {
    String? avatar,
  }) => _putProfile(SocialPaths.myProfile, displayName, avatar);

  @override
  Future<bool> deleteMyProfile() => _deleteProfile(SocialPaths.myProfile);

  @override
  Future<List<SocialProfile>> profiles(Iterable<String> ids) async {
    final answer = await _requester.send(
      'GET',
      SocialRoute.profiles,
      SocialPaths.profiles,
      query: SocialPaths.idsQuery(ids),
    );
    return <SocialProfile>[
      for (final item in _object(answer).getListOrEmpty('profiles'))
        if (item is JsonObject) SocialProfile.fromJson(item),
    ];
  }

  @override
  Future<List<SocialRelation>> friends() async {
    final answer = await _requester.send(
      'GET',
      SocialRoute.friends,
      SocialPaths.friends,
    );
    return _relations(_object(answer), 'friends');
  }

  @override
  Future<SocialRequests> requests() async {
    final answer = await _requester.send(
      'GET',
      SocialRoute.requests,
      SocialPaths.requests,
    );
    final json = _object(answer);
    return SocialRequests(
      incoming: _relations(json, 'incoming'),
      outgoing: _relations(json, 'outgoing'),
    );
  }

  @override
  Future<List<SocialRelation>> blocks() async {
    final answer = await _requester.send(
      'GET',
      SocialRoute.blocks,
      SocialPaths.blocks,
    );
    return _relations(_object(answer), 'blocks');
  }

  @override
  Future<SocialRequestResult> request(String player) async {
    final body = Json.encode(
      Json.object().set('to', SocialRules.checkPlayerId(player)).build(),
    );
    final answer = await _requester.send(
      'POST',
      SocialRoute.requests,
      SocialPaths.requests,
      body: body,
    );
    return SocialRequestResult(
      state: _object(answer).getString('state') ?? '',
      created: answer.status == 201,
    );
  }

  @override
  Future<void> accept(String player) => _done(
    'POST',
    SocialRoute.requests,
    SocialPaths.requestAction(player, 'accept'),
  );

  @override
  Future<void> decline(String player) => _done(
    'POST',
    SocialRoute.requests,
    SocialPaths.requestAction(player, 'decline'),
  );

  @override
  Future<void> withdraw(String player) =>
      _done('DELETE', SocialRoute.requests, SocialPaths.request(player));

  @override
  Future<void> unfriend(String player) =>
      _done('DELETE', SocialRoute.friends, SocialPaths.friend(player));

  @override
  Future<void> block(String player) =>
      _done('PUT', SocialRoute.blocks, SocialPaths.block(player));

  @override
  Future<void> unblock(String player) =>
      _done('DELETE', SocialRoute.blocks, SocialPaths.block(player));

  @override
  late final SocialServerCommands server = _ServerCommands(this);

  @override
  void close() => _requester.close();
}

final class _ServerCommands implements SocialServerCommands {
  _ServerCommands(this._client);
  final SocialClientImpl _client;

  @override
  Future<List<SocialRelation>> friendsOf(String player) async {
    final answer = await _client._requester.send(
      'GET',
      SocialRoute.friends,
      SocialPaths.friendsOf(player),
    );
    return SocialClientImpl._relations(
      SocialClientImpl._object(answer),
      'friends',
    );
  }

  @override
  Future<SocialProfileResult> putProfile(
    String owner,
    String displayName, {
    String? avatar,
  }) => _client._putProfile(SocialPaths.profileOf(owner), displayName, avatar);

  @override
  Future<bool> deleteProfile(String owner) =>
      _client._deleteProfile(SocialPaths.profileOf(owner));

  @override
  Future<int> deleteRelations(String player, {String? other}) async {
    final answer = await _client._requester.send(
      'DELETE',
      SocialRoute.relations,
      SocialPaths.relationsOf(player, other),
    );
    return SocialClientImpl._object(answer).getInt('deleted') ?? 0;
  }
}
