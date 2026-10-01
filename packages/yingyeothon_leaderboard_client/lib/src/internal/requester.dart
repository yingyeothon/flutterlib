import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../errors.dart';
import '../paths.dart';

/// The route kinds a log line may name: never the board, the owner or a
/// score.
enum LbRoute {
  /// `GET /lb/{board}`.
  board,

  /// `PUT`, `GET` or `DELETE …/scores/{owner}`.
  score,

  /// `GET …/top`.
  top,

  /// `DELETE …/periods/{period}`.
  period,
}

/// A 2xx answer: the status and the body.
final class LbAnswer {
  /// Creates an answer.
  const LbAnswer(this.status, this.body);

  /// The status.
  final int status;

  /// The body as text.
  final String body;
}

/// The single request choke point: one header assembly, one place the token
/// is used, one log line per request. Only the method, the route kind, the
/// status and the body size are logged. Same shape as the key-value
/// client's requester (`rules/architecture.md`), for the same reasons.
final class LbRequester {
  /// Creates a requester over [client]; [ownsClient] says whether [close]
  /// closes it.
  LbRequester({
    required http.Client client,
    required bool ownsClient,
    required Uri baseUrl,
    required String token,
    required Logger logger,
    required Duration timeout,
  }) : this._(client, ownsClient, baseUrl, 'Bearer $token', logger, timeout);

  LbRequester._(
    this._client,
    this._ownsClient,
    this._baseUrl,
    this._authorization,
    this._logger,
    this._timeout,
  );

  /// Bodies larger than this are refused before they are buffered. A full
  /// page is 100 rows with a 1 KiB `meta` each.
  static const int maxResponseBytes = 1 << 20;

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
  /// [LeaderboardException].
  Future<LbAnswer> send(
    String method,
    LbRoute route,
    List<String> segments, {
    Map<String, String> query = const <String, String>{},
    String? body,
  }) async {
    // Abortable, so a deadline releases the socket instead of leaving the
    // body buffering into a builder nobody reads.
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(
            method,
            LbPaths.resolve(_baseUrl, segments, query),
            abortTrigger: abort.future,
          )
          ..headers['accept'] = 'application/json'
          ..headers['authorization'] = _authorization;
    if (body != null) {
      // Body first: the setter would append a charset to a content type set
      // before it.
      request.body = body;
      request.headers['content-type'] = 'application/json';
    }
    final http.StreamedResponse streamed;
    final Uint8List bytes;
    try {
      // One deadline for the headers and the whole body.
      (streamed, bytes) = await _exchange(request).timeout(_timeout);
    } on LeaderboardException {
      _warn(method, route);
      rethrow;
    } on TimeoutException {
      abort.complete();
      throw _network(method, route);
    } on Exception {
      // ClientException names the URL, ArgumentError quotes the URI dart:io
      // refused, StateError is a closed client, and dart:io's own exceptions
      // quote a host or a header: none of their text crosses this line.
      throw _network(method, route);
    } on ArgumentError {
      throw _network(method, route);
    } on StateError {
      throw _network(method, route);
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    _logger.debug('lb request', <String, Object?>{
      'method': method,
      'route': route.name,
      'status': streamed.statusCode,
      'bytes': bytes.length,
    });
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw LeaderboardException.fromResponse(streamed.statusCode, text);
    }
    return LbAnswer(streamed.statusCode, text);
  }

  Future<(http.StreamedResponse, Uint8List)> _exchange(
    http.Request request,
  ) async {
    final streamed = await _client.send(request);
    final declared = streamed.contentLength;
    if (declared != null && declared > maxResponseBytes) {
      unawaited(streamed.stream.listen(null).cancel());
      throw LeaderboardException(
        streamed.statusCode,
        LeaderboardException.malformedResponseCode,
      );
    }
    final chunks = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      chunks.add(chunk);
      if (chunks.length > maxResponseBytes) {
        throw LeaderboardException(
          streamed.statusCode,
          LeaderboardException.malformedResponseCode,
        );
      }
    }
    return (streamed, chunks.takeBytes());
  }

  void _warn(String method, LbRoute route) => _logger.warn(
    'lb request failed',
    <String, Object?>{'method': method, 'route': route.name},
  );

  LeaderboardException _network(String method, LbRoute route) {
    _warn(method, route);
    return const LeaderboardException(0, LeaderboardException.networkCode);
  }
}
