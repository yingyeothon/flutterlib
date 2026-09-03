import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// What a map fetch returned.
final class HttpFetchResult {
  /// Creates a result.
  const HttpFetchResult({required this.status, required this.body});

  /// The HTTP status.
  final int status;

  /// The body, decoded as UTF-8.
  final String body;
}

/// A map fetch failed. Carries the status (or a reason code) and nothing
/// from the response body or the URL.
final class MapFetchException implements Exception {
  /// Creates the exception.
  const MapFetchException(this.status, this.reason);

  /// The HTTP status, or `0` when the request never got one.
  final int status;

  /// One of `status`, `timeout`, `tooLarge`, `network`.
  final String reason;

  @override
  String toString() => 'MapFetchException($reason, status $status)';
}

/// Fetches a map asset. The asset is public and immutable, so the request
/// carries **no credentials**; keep it that way — adding a header here would
/// send the token to a CDN.
abstract interface class MapHttpFetcher {
  /// Performs a GET. Throws [MapFetchException] for anything but a response.
  Future<HttpFetchResult> get(Uri url);
}

/// The default fetcher over `package:http`, with the bounds a URL that came
/// off the wire needs: a timeout, a response-size cap, and a redirect budget.
final class HttpMapFetcher implements MapHttpFetcher {
  /// Creates a fetcher. [client] defaults to a fresh [http.Client].
  HttpMapFetcher({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxBytes = 16 << 20,
    this.maxRedirects = 5,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// Deadline for the whole request, headers and body together.
  final Duration timeout;

  /// The response is abandoned once its body exceeds this many bytes.
  final int maxBytes;

  /// Redirect budget.
  final int maxRedirects;

  @override
  Future<HttpFetchResult> get(Uri url) async {
    final request = http.Request('GET', url)
      ..followRedirects = true
      ..maxRedirects = maxRedirects;
    // One deadline for headers and body: a per-chunk timeout would let a
    // drip-feeding host hold the fetch open indefinitely.
    final deadline = Future<Never>.delayed(
      timeout,
      () => throw const MapFetchException(0, 'timeout'),
    );
    final http.StreamedResponse response;
    try {
      response = await Future.any(<Future<http.StreamedResponse>>[
        _client.send(request),
        deadline,
      ]);
    } on http.ClientException {
      // The message names the URL; only the fact crosses.
      throw const MapFetchException(0, 'network');
    } on ArgumentError {
      // dart:io quotes the URI in its ArgumentError for a bad scheme or host.
      throw const MapFetchException(0, 'badUrl');
    }
    final declared = response.contentLength;
    if (declared != null && declared > maxBytes) {
      throw MapFetchException(response.statusCode, 'tooLarge');
    }
    final chunks = BytesBuilder(copy: false);
    final done = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.stream.listen(
      (chunk) {
        chunks.add(chunk);
        if (chunks.length > maxBytes && !done.isCompleted) {
          done.completeError(
            MapFetchException(response.statusCode, 'tooLarge'),
          );
          unawaited(subscription.cancel());
        }
      },
      onError: (Object _) {
        if (!done.isCompleted) {
          done.completeError(MapFetchException(response.statusCode, 'network'));
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      await Future.any(<Future<void>>[done.future, deadline]);
    } on MapFetchException catch (e) {
      unawaited(subscription.cancel());
      throw e.reason == 'timeout'
          ? MapFetchException(response.statusCode, 'timeout')
          : e;
    }
    return HttpFetchResult(
      status: response.statusCode,
      body: utf8.decode(chunks.takeBytes(), allowMalformed: true),
    );
  }
}
