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

  /// One of `status`, `timeout`, `tooLarge`, `network`, `badUrl`.
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
  /// Creates a fetcher. [client] defaults to a fresh [http.Client], which
  /// [close] releases; an injected one stays the caller's to close.
  HttpMapFetcher({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.maxBytes = 16 << 20,
    this.maxRedirects = 5,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// Deadline for the whole request, headers and body together.
  final Duration timeout;

  /// The response is abandoned once its body exceeds this many bytes.
  final int maxBytes;

  /// Redirect budget.
  final int maxRedirects;

  /// Closes the client this fetcher created, dropping its pooled
  /// connections and failing a fetch still in flight; an injected client is
  /// left open. Idempotent. A lobby client calls it from
  /// `close()` on the fetcher it built itself, never on one you passed.
  void close() {
    if (_ownsClient) _client.close();
  }

  @override
  Future<HttpFetchResult> get(Uri url) async {
    // Aborted at the deadline, so a host that never answers does not keep
    // the socket after the caller has moved on.
    final abort = Completer<void>();
    final request =
        http.AbortableRequest('GET', url, abortTrigger: abort.future)
          ..followRedirects = true
          ..maxRedirects = maxRedirects;
    // One deadline for headers and body: a per-chunk timeout would let a
    // drip-feeding host hold the fetch open indefinitely. A cancellable timer,
    // not `Future.delayed`: a fetch that settles must not leave a timer that
    // keeps the isolate alive for the rest of the timeout.
    final expired = Completer<Never>();
    final timer = Timer(timeout, () {
      expired.completeError(const MapFetchException(0, 'timeout'));
      abort.complete();
    });
    try {
      return await _fetch(request, expired.future);
    } finally {
      timer.cancel();
    }
  }

  Future<HttpFetchResult> _fetch(
    http.BaseRequest request,
    Future<Never> deadline,
  ) async {
    final http.StreamedResponse response;
    // Future.sync: a client that throws synchronously fails the future
    // instead, so the catches below still stand between it and the caller.
    final sending = Future<http.StreamedResponse>.sync(
      () => _client.send(request),
    );
    try {
      response = await Future.any(<Future<http.StreamedResponse>>[
        sending,
        deadline,
      ]);
    } on MapFetchException {
      // The deadline won. Headers that arrive later would hold a pooled
      // connection with a body nobody reads: cancel it when it comes.
      sending.then((answer) => answer.stream.listen(null).cancel()).ignore();
      rethrow;
    } on http.ClientException {
      // The message names the URL; only the fact crosses.
      throw const MapFetchException(0, 'network');
    } on ArgumentError {
      // dart:io quotes the URI in its ArgumentError for a bad scheme or host.
      throw const MapFetchException(0, 'badUrl');
    } on Exception {
      // IOClient converts only socket and HTTP errors; a TLS failure escapes
      // raw and may name the host.
      throw const MapFetchException(0, 'network');
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
