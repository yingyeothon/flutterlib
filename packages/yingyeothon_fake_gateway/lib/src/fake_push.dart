import 'dart:convert';
import 'dart:io';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// In-memory device registrations; tokens stay inside this fake, never diagnostics.
final class FakePushStore {
  /// Creates a store for accepted projects and an optional channel-wide cap.
  FakePushStore({this.projects = const {'demo-project'}, this.tokenCap = 1000});

  /// Accepted Firebase projects, without real credentials.
  final Set<String> projects;

  /// Channel-wide token cap, matching the service's cap refusal.
  final int tokenCap;
  final Map<(String, String), Map<String, ({String project, int refreshed})>>
  _tokens = {};

  /// Number of registrations, without exposing tokens.
  int get tokenCount =>
      _tokens.values.fold(0, (total, row) => total + row.length);

  /// Whether a caller owns a token, for assertions without returning it.
  bool contains(String user, String token, {String channel = 'push_demo'}) =>
      _tokens[(channel, user)]?.containsKey(token) ?? false;

  /// Registers or refreshes a token; returns a service refusal word or null.
  String? register(
    String user,
    String token,
    String? project, {
    required int now,
    String channel = 'push_demo',
  }) {
    if (token.isEmpty ||
        token.length > 512 ||
        token.codeUnits.any((c) => c < 33 || c > 126)) {
      return 'bad_request';
    }
    if (projects.isEmpty) return 'push_not_registered';
    if (project == null && projects.length > 1) return 'push_project_required';
    final selected = project ?? projects.first;
    if (!projects.contains(selected)) return 'push_project_refused';
    // A physical device token has exactly one owner per channel in production.
    final existing = _tokens.entries.any(
      (e) => e.key.$1 == channel && e.value.containsKey(token),
    );
    final row = _tokens.putIfAbsent((channel, user), () => {});
    if (!existing &&
        row.length < 5 &&
        _tokens.entries
                .where((e) => e.key.$1 == channel)
                .fold(0, (n, e) => n + e.value.length) >=
            tokenCap) {
      return 'channel_full';
    }
    if (row.length >= 5 && !row.containsKey(token)) row.remove(row.keys.first);
    for (final entry in _tokens.entries) {
      if (entry.key.$1 == channel && entry.key.$2 != user) {
        entry.value.remove(token);
      }
    }
    row[token] = (project: selected, refreshed: now);
    return null;
  }

  /// Deletes only the caller's own registration.
  void unregister(String user, String token, {String channel = 'push_demo'}) =>
      _tokens[(channel, user)]?.remove(token);

  /// Sweeps registrations not refreshed in sixty days.
  void sweep(int now) {
    for (final row in _tokens.values) {
      row.removeWhere((_, value) => value.refreshed < now - 60 * 86400);
    }
  }

  /// True for token routes.
  static bool handles(String path) => path.startsWith('/push/');

  /// Handles PUT/DELETE token routes over the raw loopback request.
  Future<void> handle(HttpRequest request) async {
    final auth = request.headers.value('authorization');
    var status = 204;
    String? reason;
    final segments = request.uri.pathSegments;
    if (auth == null || !auth.startsWith('Bearer ') || auth.length <= 7) {
      status = 401;
    } else if (segments.length != 3 ||
        segments.last != 'token' ||
        !['PUT', 'DELETE'].contains(request.method)) {
      status = 404;
    } else {
      final text = await utf8.decoder.bind(request).join();
      final decoded = Json.tryDecode(text);
      final body = decoded is JsonDecoded ? decoded.value : null;
      if (body is! JsonObject || body.getString('token') == null) {
        status = 400;
        reason = 'bad_request';
      } else {
        final token = body.getString('token')!;
        var user = auth.substring(7);
        try {
          final parts = user.split('.');
          if (parts.length == 3) {
            final claims = Json.decode(
              utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
            );
            if (claims is JsonObject) user = claims.getString('sub') ?? user;
          }
        } on Exception {
          /* plain identities are valid in the fake */
        }
        if (request.method == 'DELETE') {
          unregister(user, token, channel: segments[1]);
        } else {
          reason = register(
            user,
            token,
            body.getString('project'),
            now: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            channel: segments[1],
          );
          if (reason != null) {
            status = ['channel_full', 'push_not_registered'].contains(reason)
                ? 409
                : 400;
          }
        }
      }
    }
    request.response.statusCode = status;
    if (status != 204) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        Json.encode({
          'error': {
            'code': reason ?? 'http_$status',
            if (reason == 'channel_full')
              'details': {'limit': 'push.tokensPerChannel'},
          },
        }),
      );
    }
    await request.response.close();
  }
}
