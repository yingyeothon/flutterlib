import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../kvstore_client.dart';
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
  void close() => _requester.close();
}
