import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_codec/yingyeothon_codec.dart';

/// The channel's public config from `GET /c/{ch}/.well-known/config`.
final class AuthChannelConfig {
  /// Creates a config.
  const AuthChannelConfig({
    required this.channelId,
    required this.issuer,
    required this.audience,
    required this.tokenTtlSec,
    required this.providers,
    required this.callbackUrls,
    required this.startUrl,
    required this.redirectAllowlist,
    required this.raw,
    this.expiresAt,
  });

  /// Reads the config object. Missing fields read as empty.
  factory AuthChannelConfig.fromJson(JsonObject json) {
    List<String> strings(String key) =>
        json.getListOrEmpty(key).whereType<String>().toList(growable: false);
    final expires = json.getString('expiresAt');
    return AuthChannelConfig(
      channelId: json.getString('channelId') ?? '',
      issuer: json.getString('issuer') ?? '',
      audience: json.getString('audience') ?? '',
      tokenTtlSec: json.getInt('tokenTtlSec') ?? 0,
      providers: strings('providers'),
      callbackUrls: strings('callbackUrls'),
      startUrl: json.getString('startUrl') ?? '',
      redirectAllowlist: strings('redirectAllowlist'),
      expiresAt: expires == null ? null : DateTime.tryParse(expires),
      raw: json,
    );
  }

  /// The auth channel id.
  final String channelId;

  /// JWT `iss`.
  final String issuer;

  /// JWT `aud`.
  final String audience;

  /// Token lifetime in seconds (24 h by default, up to 30 days).
  final int tokenTtlSec;

  /// Providers the channel enables: `github`, `google`.
  final List<String> providers;

  /// Provider callback URLs registered for this channel.
  final List<String> callbackUrls;

  /// The `/start` URL, absolute.
  final String startUrl;

  /// URL prefixes a `redirect` must match.
  final List<String> redirectAllowlist;

  /// When the channel expires, if it does.
  final DateTime? expiresAt;

  /// The object as received.
  final JsonObject raw;
}

/// What the auth service issued.
final class ChannelToken {
  /// Creates a token.
  const ChannelToken({
    required this.jwt,
    required this.userId,
    required this.exp,
  });

  /// The value for `GatewayClientOptions.token`. A credential: never log it.
  final String jwt;

  /// The identity the token carries; the gateway echoes it as `hello.userId`.
  final String userId;

  /// Expiry as Unix seconds. There is no refresh; sign in again.
  final int exp;

  /// Expiry as a [DateTime].
  DateTime get expiresAt =>
      DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);

  /// Whether [now] is past [expiresAt].
  bool isExpired(DateTime now) => !now.toUtc().isBefore(expiresAt);

  /// Deliberately does not include the token.
  @override
  String toString() => 'ChannelToken(userId: $userId, exp: $exp)';
}

/// Why an auth call failed.
enum AuthFailureKind {
  /// The service answered with a non-2xx status; see [AuthFailure.status].
  httpStatus,

  /// The response was not JSON.
  notJson,

  /// The JSON lacked a required field.
  missingField,

  /// The redirect's nonce did not match the one sent.
  nonceMismatch,

  /// The redirect carried no fragment, or no `token` in it.
  missingFragment,

  /// The request never completed: timeout or network error.
  network,
}

/// An auth call failed. Carries a kind and a status — never a response body,
/// a token, or the URL that was called.
final class AuthFailure implements Exception {
  /// Creates a failure.
  const AuthFailure(this.kind, [this.status]);

  /// What went wrong.
  final AuthFailureKind kind;

  /// The HTTP status for [AuthFailureKind.httpStatus].
  final int? status;

  @override
  String toString() =>
      'AuthFailure(${kind.name}${status == null ? '' : ', status $status'})';
}

/// The client's half of the auth channel.
abstract interface class AuthClient {
  /// Creates a client for [channelId] at [baseUrl] (for example
  /// `https://auth.yyt.life`). [httpClient] defaults to a fresh
  /// [http.Client]; inject one to test or to share a connection pool.
  factory AuthClient({
    required Uri baseUrl,
    required String channelId,
    http.Client? httpClient,
    Duration timeout,
  }) = _AuthClient;

  /// `GET /c/{ch}/.well-known/config`. Unauthenticated.
  Future<AuthChannelConfig> fetchConfig();

  /// Builds `GET /c/{ch}/start?provider=…&redirect=…` for the browser.
  ///
  /// [redirect] must be on the channel's allowlist (its origin and path
  /// prefix are matched; a query string is allowed, which is where [nonce]
  /// goes, under [nonceParameter]). The auth service appends
  /// `#token=…&userId=…&exp=…` to it when the sign-in completes.
  Uri buildStartUrl({
    required String provider,
    required Uri redirect,
    required String nonce,
    String nonceParameter = 'nonce',
  });

  /// Reads the token out of the URI the browser came back to.
  ///
  /// Checks that the query's [nonceParameter] equals [expectedNonce] in
  /// constant time and that the fragment carries `token`. Throws
  /// [AuthFailure]. **Discard [returned] after this call**: its fragment is a
  /// credential.
  ChannelToken parseRedirect(
    Uri returned, {
    required String expectedNonce,
    String nonceParameter = 'nonce',
  });

  /// `POST /c/{ch}/token` with a provider credential. Exactly one of
  /// [accessToken] (GitHub) or [idToken] (Google) must be given.
  Future<ChannelToken> exchange({
    required String provider,
    String? accessToken,
    String? idToken,
  });

  /// `GET /c/{ch}/verify` with the bearer. Returns `null` for `401`; throws
  /// [AuthFailure] for anything else that is not a `200`.
  Future<ChannelToken?> verify(String jwt);

  /// A fresh URL-safe nonce (32 random bytes, base64url without padding).
  static String newNonce([Random? random]) {
    final r = random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => r.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

final class _AuthClient implements AuthClient {
  _AuthClient({
    required Uri baseUrl,
    required this.channelId,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : baseUrl = _stripTrailingSlash(baseUrl),
       _http = httpClient ?? http.Client();

  final Uri baseUrl;
  final String channelId;
  final Duration timeout;
  final http.Client _http;

  static Uri _stripTrailingSlash(Uri url) {
    final path = url.path;
    return path.endsWith('/')
        ? url.replace(path: path.substring(0, path.length - 1))
        : url;
  }

  Uri _channelUrl(String suffix, [Map<String, String>? query]) =>
      baseUrl.replace(
        path: '${baseUrl.path}/c/${Uri.encodeComponent(channelId)}$suffix',
        queryParameters: query,
      );

  @override
  Future<AuthChannelConfig> fetchConfig() async {
    final json = await _getJson(_channelUrl('/.well-known/config'));
    return AuthChannelConfig.fromJson(json);
  }

  @override
  Uri buildStartUrl({
    required String provider,
    required Uri redirect,
    required String nonce,
    String nonceParameter = 'nonce',
  }) {
    final withNonce = redirect.replace(
      queryParameters: <String, String>{
        ...redirect.queryParameters,
        nonceParameter: nonce,
      },
    );
    return _channelUrl('/start', <String, String>{
      'provider': provider,
      'redirect': withNonce.toString(),
    });
  }

  @override
  ChannelToken parseRedirect(
    Uri returned, {
    required String expectedNonce,
    String nonceParameter = 'nonce',
  }) {
    final String? nonce;
    final Map<String, String> params;
    try {
      // Both decoders throw ArgumentError on a bad percent-escape, and that
      // message must not escape as anything but a kind.
      nonce = returned.queryParameters[nonceParameter];
      params = returned.hasFragment && returned.fragment.isNotEmpty
          ? Uri.splitQueryString(returned.fragment)
          : const <String, String>{};
    } on ArgumentError {
      throw const AuthFailure(AuthFailureKind.missingFragment);
    }
    if (nonce == null || !_constantTimeEquals(nonce, expectedNonce)) {
      throw const AuthFailure(AuthFailureKind.nonceMismatch);
    }
    if (params.isEmpty) {
      throw const AuthFailure(AuthFailureKind.missingFragment);
    }
    final jwt = params['token'];
    if (jwt == null || jwt.isEmpty) {
      throw const AuthFailure(AuthFailureKind.missingFragment);
    }
    return ChannelToken(
      jwt: jwt,
      userId: params['userId'] ?? '',
      exp: int.tryParse(params['exp'] ?? '') ?? 0,
    );
  }

  @override
  Future<ChannelToken> exchange({
    required String provider,
    String? accessToken,
    String? idToken,
  }) async {
    if ((accessToken == null) == (idToken == null)) {
      throw ArgumentError('give exactly one of accessToken or idToken');
    }
    final body = Json.object()
        .set('provider', provider)
        .set('accessToken', accessToken)
        .set('idToken', idToken)
        .build();
    final json = await _postJson(_channelUrl('/token'), body);
    return _tokenFrom(json, 'jwt');
  }

  @override
  Future<ChannelToken?> verify(String jwt) async {
    final response = await _send(
      http.Request('GET', _channelUrl('/verify'))
        ..headers['authorization'] = 'Bearer $jwt',
    );
    if (response.statusCode == 401) return null;
    final json = _decode(response);
    final token = _tokenFrom(json, null);
    return ChannelToken(jwt: jwt, userId: token.userId, exp: token.exp);
  }

  // ---- plumbing ------------------------------------------------------------

  Future<JsonObject> _getJson(Uri url) async =>
      _decode(await _send(http.Request('GET', url)));

  Future<JsonObject> _postJson(Uri url, JsonObject body) async {
    final request = http.Request('POST', url)
      ..headers['content-type'] = 'application/json'
      ..body = Json.encode(body);
    return _decode(await _send(request));
  }

  /// Bodies larger than this are refused before they are buffered; an auth
  /// answer is a few hundred bytes.
  static const int maxResponseBytes = 1 << 20;

  Future<http.Response> _send(http.Request request) async {
    request.headers['accept'] = 'application/json';
    try {
      final streamed = await _http.send(request).timeout(timeout);
      final declared = streamed.contentLength;
      if (declared != null && declared > maxResponseBytes) {
        throw const AuthFailure(AuthFailureKind.notJson);
      }
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream.timeout(timeout)) {
        chunks.add(chunk);
        if (chunks.length > maxResponseBytes) {
          throw const AuthFailure(AuthFailureKind.notJson);
        }
      }
      return http.Response.bytes(
        chunks.takeBytes(),
        streamed.statusCode,
        headers: streamed.headers,
        request: request,
      );
    } on TimeoutException {
      throw const AuthFailure(AuthFailureKind.network);
    } on http.ClientException {
      // The message names the URL.
      throw const AuthFailure(AuthFailureKind.network);
    } on ArgumentError {
      throw const AuthFailure(AuthFailureKind.network);
    }
  }

  static JsonObject _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // The body may quote the credential back; the status is the report.
      throw AuthFailure(AuthFailureKind.httpStatus, response.statusCode);
    }
    final decoded = Json.tryDecode(response.body);
    if (decoded is! JsonDecoded || decoded.value is! Map<String, Object?>) {
      throw AuthFailure(AuthFailureKind.notJson, response.statusCode);
    }
    return decoded.value! as JsonObject;
  }

  static ChannelToken _tokenFrom(JsonObject json, String? jwtField) {
    final jwt = jwtField == null ? '' : (json.getString(jwtField) ?? '');
    if (jwtField != null && jwt.isEmpty) {
      throw const AuthFailure(AuthFailureKind.missingField);
    }
    final userId = json.getString('userId');
    final exp = json.getInt('exp');
    if (userId == null || exp == null) {
      throw const AuthFailure(AuthFailureKind.missingField);
    }
    return ChannelToken(jwt: jwt, userId: userId, exp: exp);
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }
}
