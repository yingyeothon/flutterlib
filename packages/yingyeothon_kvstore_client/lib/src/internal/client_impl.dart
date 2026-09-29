import 'package:http/http.dart' as http;
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../errors.dart';
import '../kvstore_client.dart';
import '../paths.dart';
import 'collection_impl.dart';
import 'requester.dart';

/// The client: one requester, many collections.
final class KvStoreClientImpl implements KvStoreClient {
  /// Creates the client; a `null` `client` option is one this owns.
  KvStoreClientImpl(KvStoreClientOptions options)
    : _requester = KvRequester(
        client: options.client ?? http.Client(),
        ownsClient: options.client == null,
        baseUrl: _checkBaseUrl(options.baseUrl),
        token: _checkToken(options.token),
        logger: options.logger ?? nullLogger,
        timeout: options.timeout ?? defaultTimeout,
      );

  /// The deadline when `KvStoreClientOptions.timeout` is `null`.
  static const Duration defaultTimeout = Duration(seconds: 15);

  final KvRequester _requester;

  static const int _maxEpochMs = 8640000000000000;

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
      'kv baseUrl must be an absolute http(s) URL with no user info, query or '
      'fragment',
    );
  }

  /// A bearer token is printable ASCII without spaces. `dart:io` refuses any
  /// other header value with a `FormatException` that quotes the whole
  /// header, so the check happens here, and names the index only.
  static String _checkToken(String token) {
    if (token.isEmpty) throw ArgumentError('kv token is required');
    for (var i = 0; i < token.length; i++) {
      final unit = token.codeUnitAt(i);
      if (unit <= 0x20 || unit >= 0x7f) {
        throw ArgumentError('kv token has an illegal character at index $i');
      }
    }
    return token;
  }

  @override
  KvCollection collection(String nameOrId) =>
      KvCollectionImpl(_requester, nameOrId);

  @override
  Future<DateTime> serverTime() async {
    final answer = await _requester.send(
      'GET',
      KvRoute.time,
      KvPaths.time,
      authorized: false,
    );
    final decoded = Json.tryDecode(answer.body);
    final value = decoded is JsonDecoded ? decoded.value : null;
    final epochMs = value is JsonObject ? value.getInt('epochMs') : null;
    // `DateTime`'s own range; past it the constructor throws a message that
    // quotes the number.
    if (epochMs == null || epochMs <= 0 || epochMs > _maxEpochMs) {
      throw KvStoreException(
        answer.status,
        KvStoreException.malformedResponseCode,
      );
    }
    return DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
  }

  @override
  void close() => _requester.close();
}
