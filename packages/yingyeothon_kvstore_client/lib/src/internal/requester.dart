import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../errors.dart';
import '../paths.dart';

/// The route kinds a log line may name: never the collection, the owner or
/// the key.
enum KvRoute {
  /// `GET /kv/{col}`.
  meta,

  /// `GET …/entries`.
  entries,

  /// `GET`, `PUT` or `DELETE …/entries/{key}`.
  entry,

  /// `PATCH …/entries/{key}`.
  incr,
}

/// A 2xx answer: the status, the headers (lower-cased names) and the body.
final class KvAnswer {
  /// Creates an answer.
  KvAnswer(this.status, this.headers, this.body);

  /// The status.
  final int status;

  /// The headers, names lower-cased.
  final Map<String, String> headers;

  /// The body as text.
  final String body;

  /// The version from `ETag`, or `null`.
  int? get version => KvStoreException.parseEtagVersion(headers['etag']);

  /// The absolute second from `X-KV-Expires-At`, or `null`.
  int? get expiresAt =>
      KvStoreException.parseExpiresAt(headers['x-kv-expires-at']);
}

/// The single request choke point: one header assembly, one place the token
/// is used, one log line per request. Only the method, the route kind, the
/// status and the body size are logged.
final class KvRequester {
  /// Creates a requester over [client]; [ownsClient] says whether [close]
  /// closes it.
  KvRequester({
    required http.Client client,
    required bool ownsClient,
    required Uri baseUrl,
    required String token,
    required Logger logger,
    required Duration timeout,
  }) : this._(client, ownsClient, baseUrl, 'Bearer $token', logger, timeout);

  KvRequester._(
    this._client,
    this._ownsClient,
    this._baseUrl,
    this._authorization,
    this._logger,
    this._timeout,
  );

  /// Bodies larger than this are refused before they are buffered. A full
  /// page with values is 100 entries of 16 KiB plus their rows.
  static const int maxResponseBytes = 4 << 20;

  final http.Client _client;
  final bool _ownsClient;
  final Uri _baseUrl;
  final String _authorization;
  final Logger _logger;
  final Duration _timeout;
  bool _closed = false;

  /// Closes the owned client once.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  /// Sends one request and returns its 2xx answer; a refusal is a
  /// [KvStoreException].
  Future<KvAnswer> send(
    String method,
    KvRoute route,
    List<String> segments, {
    Map<String, String> query = const <String, String>{},
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    // Abortable, so a deadline releases the socket instead of leaving the
    // body buffering into a builder nobody reads.
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(
            method,
            KvPaths.resolve(_baseUrl, segments, query),
            abortTrigger: abort.future,
          )
          ..headers['authorization'] = _authorization
          ..headers['accept'] = 'application/json'
          ..headers.addAll(headers);
    if (body != null) {
      // Body first: the setter would append a charset to a content type set
      // before it, and the header is pinned by a test.
      request.body = body;
      request.headers['content-type'] = 'application/json';
    }
    final http.StreamedResponse streamed;
    final Uint8List bytes;
    try {
      // One deadline for the headers and the whole body: a drip-fed body
      // cannot stretch it by arriving one chunk at a time.
      (streamed, bytes) = await _exchange(request).timeout(_timeout);
    } on KvStoreException {
      _warn(method, route);
      rethrow;
    } on TimeoutException {
      abort.complete();
      throw _network(method, route);
    } on http.ClientException {
      // The message names the URL.
      throw _network(method, route);
    } on ArgumentError {
      // dart:io quotes the URI it refused.
      throw _network(method, route);
    } on StateError {
      // A closed client.
      throw _network(method, route);
    } on Exception {
      // dart:io's FormatException, HandshakeException, SocketException from
      // the body stream: each quotes a host, a header or a URL.
      throw _network(method, route);
    }
    final lowered = <String, String>{
      for (final e in streamed.headers.entries) e.key.toLowerCase(): e.value,
    };
    final text = utf8.decode(bytes, allowMalformed: true);
    _logger.debug('kv request', <String, Object?>{
      'method': method,
      'route': route.name,
      'status': streamed.statusCode,
      'bytes': bytes.length,
    });
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw KvStoreException.fromResponse(streamed.statusCode, text);
    }
    return KvAnswer(streamed.statusCode, lowered, text);
  }

  Future<(http.StreamedResponse, Uint8List)> _exchange(
    http.Request request,
  ) async {
    final streamed = await _client.send(request);
    final declared = streamed.contentLength;
    if (declared != null && declared > maxResponseBytes) {
      unawaited(streamed.stream.listen(null).cancel());
      throw KvStoreException(
        streamed.statusCode,
        KvStoreException.malformedResponseCode,
      );
    }
    final chunks = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      chunks.add(chunk);
      if (chunks.length > maxResponseBytes) {
        throw KvStoreException(
          streamed.statusCode,
          KvStoreException.malformedResponseCode,
        );
      }
    }
    return (streamed, chunks.takeBytes());
  }

  void _warn(String method, KvRoute route) => _logger.warn(
    'kv request failed',
    <String, Object?>{'method': method, 'route': route.name},
  );

  KvStoreException _network(String method, KvRoute route) {
    _warn(method, route);
    return const KvStoreException(0, KvStoreException.networkCode);
  }
}
