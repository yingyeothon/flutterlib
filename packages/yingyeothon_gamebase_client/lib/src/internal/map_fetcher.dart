import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../transport/http_fetcher.dart';

/// Fetches immutable map assets, cached per URL.
///
/// Concurrent calls for one URL share one request; a success is kept until a
/// different URL is asked for (a new map version is a new URL, and a gateway
/// rotating URLs must not grow memory); a failure is evicted so the next call
/// retries. The cache entry is published before the work starts, so a
/// fetcher that fails synchronously still evicts the right entry.
final class MapFetcher {
  /// Creates a fetcher.
  MapFetcher({MapHttpFetcher? http, Logger? logger})
    : _http = http ?? HttpMapFetcher(),
      _logger = logger ?? nullLogger;

  final MapHttpFetcher _http;
  final Logger _logger;
  final Map<String, Future<Object?>> _cache = <String, Future<Object?>>{};

  /// The parsed body: a JSON value, or the text when it is not JSON (or is
  /// larger than [Json.maxBigLength], which is refused as a failure rather
  /// than degraded to text).
  Future<Object?> fetch(String mapUrl) {
    final cached = _cache[mapUrl];
    if (cached != null) return cached;
    _cache.clear();
    // The URL came off the wire; a pre-signed one would carry its signature.
    _logger.debug('fetching map', <String, Object?>{
      'urlLength': mapUrl.length,
    });
    late final Future<Object?> pending;
    pending = Future<Object?>.sync(() => _load(mapUrl)).catchError((Object e) {
      if (identical(_cache[mapUrl], pending)) _cache.remove(mapUrl);
      throw e;
    });
    _cache[mapUrl] = pending;
    return pending;
  }

  Future<Object?> _load(String mapUrl) async {
    // The URL came off the wire. Anything but an absolute http(s) URL with a
    // host is refused here, before dart:io can quote it in an ArgumentError.
    final url = Uri.tryParse(mapUrl);
    if (url == null ||
        (url.scheme != 'http' && url.scheme != 'https') ||
        url.host.isEmpty) {
      throw const MapFetchException(0, 'badUrl');
    }
    final result = await _http.get(url);
    if (result.status < 200 || result.status >= 300) {
      throw MapFetchException(result.status, 'status');
    }
    return switch (Json.tryDecodeBig(result.body)) {
      JsonDecoded(:final value) => value,
      JsonRefused(:final failure) =>
        failure.error == JsonParseError.inputTooLong
            ? throw MapFetchException(result.status, 'tooLarge')
            : result.body,
    };
  }
}
