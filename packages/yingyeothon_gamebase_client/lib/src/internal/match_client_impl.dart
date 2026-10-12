import 'dart:async';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';

import '../match_client.dart';
import '../transport/web_socket.dart';
import '../transport/web_socket_channel_transport.dart';
import 'http_wire.dart';

MatchException _failure(
  int status,
  String code,
  String? reason,
  Duration? retry,
) => MatchException(status, code, reason: reason, retryAfter: retry);
Never _malformed() => throw const MatchException(200, 'malformed_response');
MatchResult _result(Object? value) {
  if (value is! JsonObject) _malformed();
  final id = value.getString('matchId');
  final partial = value.getBool('partial');
  final members = value['members'];
  if (id == null ||
      id.isEmpty ||
      partial == null ||
      members is! List ||
      !value.has('result')) {
    _malformed();
  }
  final parsed = <MatchMember>[];
  for (final member in members) {
    if (member is! JsonObject) _malformed();
    final userId = member.getString('userId');
    if (userId == null || userId.isEmpty) _malformed();
    parsed.add(MatchMember(userId, member));
  }
  return MatchResult(
    matchId: id,
    partial: partial,
    result: value['result'],
    members: parsed,
    raw: value,
  );
}

MatchTicket _ticket(Object? value) {
  if (value is! JsonObject) _malformed();
  final state = value.getString('state');
  final id = value.getString('matchId');
  switch (state) {
    case 'waiting':
      if (value.getInt('position') == null || value.getInt('waited') == null) {
        _malformed();
      }
    case 'proposed':
      if (id == null ||
          value.getInt('acceptBy') == null ||
          value.getBool('accepted') == null ||
          value.getBool('partial') == null) {
        _malformed();
      }
    case 'confirmed':
      return MatchTicket(state: state!, raw: value, confirmed: _result(value));
    case 'declined':
      if (id == null) _malformed();
    case 'expired':
      if (!['wait', 'accept'].contains(value['reason'])) _malformed();
    case 'failed':
      if (!['callback', 'closed'].contains(value['reason'])) _malformed();
    default:
      _malformed();
  }
  return MatchTicket(state: state!, raw: value);
}

/// Wire implementation; constructed through its public interface.
final class DeferredMatchClientImpl implements DeferredMatchClient {
  /// Copies and validates connection options.
  DeferredMatchClientImpl(DeferredMatchClientOptions options)
    : _channel = checkChannel(options.channelId),
      _wire = HttpWire(
        base: options.apiBase,
        token: options.token,
        client: options.client,
        logger: options.logger,
        timeout: options.timeout,
        failure: _failure,
        isFailure: (error) => error is MatchException,
        label: 'match',
      ) {
    final expected = resolve(_wire.base, ['m', _channel, 'ticket']);
    if (options.ticketUrl != null && options.ticketUrl != expected) {
      _wire.close();
      throw ArgumentError('ticketUrl must match apiBase and channel');
    }
  }
  final String _channel;
  final HttpWire _wire;
  Future<MatchTicket> _request(String method, String route) async =>
      _ticket(await _wire.send(method, route, ['m', _channel, route]));
  @override
  Future<MatchTicket> submit() => _request('POST', 'ticket');
  @override
  Future<MatchTicket?> status() async {
    try {
      return await _request('GET', 'ticket');
    } on MatchException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<void> cancel() async {
    await _wire.send(
      'DELETE',
      'ticket',
      ['m', _channel, 'ticket'],
      statuses: {204},
    );
  }

  @override
  Future<MatchTicket> accept() => _request('POST', 'accept');
  @override
  Future<MatchTicket> decline() => _request('POST', 'decline');
  @override
  void close() => _wire.close();
}

/// Wire implementation; constructed through its public interface.
final class LiveMatchClientImpl implements LiveMatchClient {
  /// Copies and validates connection options.
  LiveMatchClientImpl(this._options)
    : _url = checkBase(
        _options.url,
        socket: true,
      ).replace(queryParameters: {'channel': checkChannel(_options.channelId)}),
      _token = checkCredential(_options.token) {
    if (_options.timeout <= Duration.zero) {
      throw ArgumentError('timeout must be positive');
    }
  }
  final LiveMatchClientOptions _options;
  final Uri _url;
  final String _token;
  GatewayWebSocket? _socket;
  // Canceled by _finish on every terminal path and by close via cancel.
  // ignore: cancel_subscriptions
  StreamSubscription<SocketEvent>? _subscription;
  Completer<MatchResult>? _pending;
  Timer? _timer;
  bool _closed = false;
  @override
  Future<MatchResult> find() {
    if (_closed) throw StateError('client is closed');
    if (_pending != null) return _pending!.future;
    final pending = Completer<MatchResult>();
    _pending = pending;
    try {
      final socket =
          (_options.webSocketFactory ?? const WebSocketChannelFactory())
              .connect(
                GatewayWebSocketRequest(
                  url: _url,
                  subprotocols: ['bearer', _token],
                ),
              );
      _socket = socket;
      _timer = Timer(
        _options.timeout,
        () => _finish(error: const MatchException(0, 'unavailable')),
      );
      _subscription = socket.events.listen(
        (event) {
          if (_socket != socket) return;
          switch (event) {
            case SocketOpened(:final protocol):
              if (protocol != 'bearer') {
                _finish(error: const MatchException(0, 'handshake'));
              }
            case SocketTextMessage(:final text):
              final decoded = Json.tryDecode(text);
              final value = decoded is JsonDecoded ? decoded.value : null;
              if (value is! JsonObject || value.getString('type') == null) {
                _finish(error: const MatchException(0, 'malformed_response'));
                return;
              }
              switch (value['type']) {
                case 'matched':
                  try {
                    _finish(result: _result(value));
                  } on MatchException catch (e) {
                    _finish(error: e);
                  }
                case 'failed':
                  _finish(
                    error: MatchException(
                      0,
                      'unavailable',
                      reason: safeWord(value['reason']),
                    ),
                  );
                case 'replaced':
                  _finish(error: const MatchException(0, 'cancelled'));
              }
            case SocketClosed():
              _finish(error: const MatchException(0, 'network'));
            case SocketBinaryMessage():
              _finish(error: const MatchException(0, 'malformed_response'));
          }
        },
        onError: (Object _) =>
            _finish(error: const MatchException(0, 'network')),
        onDone: () {
          if (_socket == socket) {
            _finish(error: const MatchException(0, 'network'));
          }
        },
      );
    } on Exception {
      _finish(error: const MatchException(0, 'network'));
    } on ArgumentError {
      _finish(error: const MatchException(0, 'network'));
    } on StateError {
      _finish(error: const MatchException(0, 'network'));
    }
    return pending.future;
  }

  void _finish({MatchResult? result, MatchException? error}) {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    final socket = _socket;
    _socket = null;
    _timer?.cancel();
    _timer = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    try {
      socket?.close(1000, '');
    } on Exception {
      /* outcome is already known */
    } on StateError {
      /* outcome is already known */
    }
    if (error != null) {
      pending.completeError(error);
    } else {
      pending.complete(result!);
    }
  }

  @override
  void cancel() => _finish(error: const MatchException(0, 'cancelled'));
  @override
  Future<void> close() async {
    _closed = true;
    cancel();
  }
}

/// Wire implementation; constructed through its public interface.
final class GatewayPresenceClientImpl implements GatewayPresenceClient {
  /// Copies and validates connection options.
  GatewayPresenceClientImpl(GatewayPresenceClientOptions options)
    : _channel = checkChannel(options.channelId),
      _wire = HttpWire(
        base: options.baseUrl,
        token: options.token,
        client: options.client,
        logger: options.logger,
        timeout: options.timeout,
        failure: _failure,
        isFailure: (error) => error is MatchException,
        label: 'presence',
      );
  final String _channel;
  final HttpWire _wire;
  @override
  Future<List<GatewayPresence>> users(List<String> ids) async {
    if (ids.length > 50 ||
        ids.any((id) => !RegExp(r'^[a-f0-9]{32}$').hasMatch(id))) {
      throw ArgumentError('presence needs at most 50 player ids');
    }
    if (ids.isEmpty) return const [];
    final value = await _wire.send(
      'GET',
      'presence',
      ['presence'],
      query: {'channel': _channel, 'users': ids.join(',')},
    );
    if (value is! JsonObject || value['users'] is! List) _malformed();
    final result = <GatewayPresence>[];
    for (final user in value.getListOrEmpty('users')) {
      if (user is! JsonObject ||
          user.getString('userId') == null ||
          user.getBool('online') == null) {
        _malformed();
      }
      result.add(
        GatewayPresence(user.getString('userId')!, user.getBool('online')!),
      );
    }
    return List.unmodifiable(result);
  }

  @override
  void close() => _wire.close();
}
