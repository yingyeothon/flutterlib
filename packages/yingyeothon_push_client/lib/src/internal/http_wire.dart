import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

/// Builds a package-specific failure without carrying transport text.
typedef Failure = Exception Function(
  int status,
  String code,
  String? reason,
  Duration? retryAfter,
);

/// Refuses unsafe bases before a credential can be sent.
Uri checkBase(Uri base, {bool socket = false}) {
  if (!(socket ? ['ws', 'wss'] : ['http', 'https']).contains(base.scheme) ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty ||
      base.hasQuery ||
      base.hasFragment) {
    throw ArgumentError(
      'base must be an absolute URL without credentials, query or fragment',
    );
  }
  return base;
}

/// Validates header-safe credentials without quoting input.
String checkCredential(String token) {
  if (token.isEmpty || token.codeUnits.any((c) => c < 33 || c > 126)) {
    throw ArgumentError('credential must be nonempty printable ASCII');
  }
  return token;
}

/// Validates a channel used as a path segment.
String checkChannel(String id) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
    throw ArgumentError('channel must be a path identifier');
  }
  return id;
}

/// Appends encoded segments to a checked base.
Uri resolve(
  Uri base,
  List<String> segments, [
  Map<String, String> query = const {},
]) => base.replace(
  pathSegments: [...base.pathSegments.where((s) => s.isNotEmpty), ...segments],
  queryParameters: query.isEmpty ? null : query,
);
final _word = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// Keeps only bounded service error words for diagnostics.
String? safeWord(Object? value) =>
    value is String && _word.hasMatch(value) ? value : null;

/// Bounded, abortable authenticated exchange shared within this package.
final class HttpWire {
  /// Validates options before allocating an owned client.
  HttpWire({
    required Uri base,
    required String token,
    http.Client? client,
    Logger? logger,
    required Duration timeout,
    required this.failure,
    required this.isFailure,
    required this.label,
  }) : base = checkBase(base),
       _token = checkCredential(token),
       _timeout = _checkTimeout(timeout),
       _logger = logger ?? nullLogger,
       _client = client ?? http.Client(),
       _owns = client == null;

  /// The checked base, never logged.
  final Uri base;
  final String _token;
  final Duration _timeout;
  final Logger _logger;
  final http.Client _client;
  final bool _owns;

  /// Maps refusal fields to this package's safe exception.
  final Failure failure;

  /// Identifies mapped errors that must survive transport sanitization.
  final bool Function(Object) isFailure;

  /// Fixed log prefix.
  final String label;
  final Set<Completer<void>> _aborts = {};
  bool _closed = false;

  /// Aborts requests and closes only the owned HTTP client.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in _aborts.toList()) {
      if (!abort.isCompleted) abort.complete();
    }
    if (_owns) _client.close();
  }

  /// Sends one request with a deadline across headers and body.
  Future<Object?> send(
    String method,
    String route,
    List<String> segments, {
    Object? body,
    Map<String, String> query = const {},
    Set<int> statuses = const {200, 204},
  }) async {
    if (_closed) throw StateError('client is closed');
    final abort = Completer<void>();
    _aborts.add(abort);
    final request =
        http.AbortableRequest(
            method,
            resolve(base, segments, query),
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers['authorization'] = 'Bearer $_token'
          ..headers['accept'] = 'application/json';
    if (body != null) {
      request.body = Json.encode(body);
      request.headers['content-type'] = 'application/json';
    }
    try {
      final (response, bytes) = await _exchange(request).timeout(_timeout);
      _logger.debug('$label request', {
        'method': method,
        'route': route,
        'status': response.statusCode,
        'bytes': bytes.length,
      });
      final decoded = Json.tryDecode(utf8.decode(bytes, allowMalformed: true));
      final value = decoded is JsonDecoded ? decoded.value : null;
      if (!statuses.contains(response.statusCode)) {
        final error = value is JsonObject ? value.getObject('error') : null;
        final details = error?.getObject('details');
        final seconds = details?.getInt('retryAfter');
        throw failure(
          response.statusCode,
          safeWord(error?['code']) ?? 'http_${response.statusCode}',
          safeWord(details?['reason']),
          seconds != null && seconds >= 0 && seconds <= 86400
              ? Duration(seconds: seconds)
              : null,
        );
      }
      if (response.statusCode == 204) return null;
      if (decoded is! JsonDecoded) {
        throw failure(response.statusCode, 'malformed_response', null, null);
      }
      return value;
    } on TimeoutException {
      throw failure(0, 'network', null, null);
    } on http.ClientException {
      throw failure(0, 'network', null, null);
    } on FormatException {
      throw failure(0, 'malformed_response', null, null);
    } on ArgumentError {
      throw failure(0, 'network', null, null);
    } on StateError {
      throw failure(0, 'network', null, null);
    } on Exception catch (error) {
      if (isFailure(error)) rethrow;
      throw failure(0, 'network', null, null);
    } finally {
      if (!abort.isCompleted) abort.complete();
      _aborts.remove(abort);
    }
  }

  Future<(http.StreamedResponse, Uint8List)> _exchange(
    http.Request request,
  ) async {
    final response = await _client.send(request);
    final declared = response.contentLength;
    if (declared != null && declared > 1 << 20) {
      await response.stream.listen((_) {}).cancel();
      throw failure(response.statusCode, 'malformed_response', null, null);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (builder.length + chunk.length > 1 << 20) {
        throw failure(response.statusCode, 'malformed_response', null, null);
      }
      builder.add(chunk);
    }
    return (response, builder.takeBytes());
  }
}

Duration _checkTimeout(Duration timeout) {
  if (timeout <= Duration.zero) throw ArgumentError('timeout must be positive');
  return timeout;
}
