import 'dart:async';

import '../push_client.dart';
import 'emitter.dart';
import 'http_wire.dart';

/// Injectable device registration implementation.
final class PushClientImpl implements PushClient {
  /// Validates options and prepares the HTTP requester.
  PushClientImpl(this._options)
    : _channel = checkChannel(_options.channelId),
      _wire = HttpWire(
        base: _options.apiBase,
        token: _options.token,
        client: _options.client,
        logger: _options.logger,
        timeout: _options.timeout,
        failure: (status, code, reason, _) =>
            PushException(status, code, reason: reason),
        label: 'push',
        isFailure: (error) => error is PushException,
      ) {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(_options.project) ||
        _options.topic.isEmpty ||
        !RegExp(r'^[a-zA-Z0-9\-_.~%]+$').hasMatch(_options.topic)) {
      _wire.close();
      throw ArgumentError(
        'project and configured topic must be valid Firebase identifiers',
      );
    }
  }
  final PushClientOptions _options;
  final String _channel;
  final HttpWire _wire;
  final Emitter<ClassifiedPush> _received = Emitter<ClassifiedPush>();
  final Emitter<PushException> _refused = Emitter<PushException>();
  StreamSubscription<String>? _refresh;
  StreamSubscription<PushMessage>? _messages;
  Future<void> _tail = Future.value();
  bool _closed = false;
  bool _started = false;
  bool _signingOut = false;
  int _generation = 0;
  String? _registered;
  bool _subscribed = false;
  @override
  Stream<ClassifiedPush> get received => _received.stream;
  @override
  Stream<PushException> get refused => _refused.stream;
  Future<void> _serial(Future<void> Function() action) {
    if (_closed) throw StateError('client is closed');
    final task = _tail.then((_) {
      if (_closed) throw StateError('client is closed');
      return action();
    });
    _tail = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  Future<T> _device<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(_options.timeout);
    } on Exception {
      throw const PushException(0, 'device');
    } on StateError {
      throw const PushException(0, 'device');
    } on ArgumentError {
      throw const PushException(0, 'device');
    }
  }

  @override
  Future<void> start() async {
    final messaging = _options.messaging;
    if (messaging == null) throw StateError('messaging adapter is required');
    if (_closed) throw StateError('client is closed');
    if (_signingOut) throw const PushException(0, 'cancelled');
    final generation = _generation;
    if (!_started) {
      _started = true;
      _messages = messaging.messages.listen(
        (message) {
          if (!_closed) _received.emit(classifyPush(message));
        },
        onError: (Object _) {
          if (!_closed) _refused.emit(const PushException(0, 'device'));
        },
      );
      _refresh = messaging.tokenRefreshed.listen(
        (token) {
          if (_closed || _signingOut || generation != _generation) return;
          unawaited(
            Future<void>.sync(() => register(token)).catchError((Object error) {
              if (!_closed && !_signingOut && generation == _generation) {
                _refused.emit(
                  error is PushException
                      ? error
                      : const PushException(0, 'device'),
                );
              }
            }),
          );
        },
        onError: (Object _) {
          if (!_closed) _refused.emit(const PushException(0, 'device'));
        },
      );
    }
    final token = await _device(messaging.getToken);
    if (token != null &&
        !_closed &&
        !_signingOut &&
        generation == _generation) {
      await register(token);
    }
  }

  @override
  Future<void> register(String deviceToken) {
    if (deviceToken.isEmpty ||
        deviceToken.length > 512 ||
        deviceToken.codeUnits.any((c) => c < 33 || c > 126)) {
      throw ArgumentError(
        'device token must be printable ASCII and at most 512 characters',
      );
    }
    final generation = _generation;
    return _serial(() async {
      if (_signingOut || generation != _generation) {
        throw const PushException(0, 'cancelled');
      }
      await _wire.send(
        'PUT',
        'token',
        ['push', _channel, 'token'],
        body: {'token': deviceToken, 'project': _options.project},
        statuses: {204},
      );
      _registered = deviceToken;
      if (!_closed &&
          !_signingOut &&
          generation == _generation &&
          !_subscribed &&
          _options.messaging != null) {
        await _device(() => _options.messaging!.subscribe(_options.topic));
        _subscribed = true;
      }
    });
  }

  @override
  Future<void> unregister() {
    _generation++;
    _signingOut = true;
    return _serial(() async {
      // Stop refreshes first so a rotation cannot re-register after sign-out.
      await _refresh?.cancel();
      _refresh = null;
      await _messages?.cancel();
      _messages = null;
      _started = false;
      PushException? failure;
      try {
        if (_registered != null) {
          await _wire.send(
            'DELETE',
            'token',
            ['push', _channel, 'token'],
            body: {'token': _registered},
            statuses: {204},
          );
        }
        _registered = null;
      } on PushException catch (e) {
        failure = e;
      }
      if (_subscribed && _options.messaging != null) {
        try {
          await _device(() => _options.messaging!.unsubscribe(_options.topic));
          _subscribed = false;
        } on PushException catch (e) {
          failure ??= e;
        }
      }
      if (failure != null) throw failure;
    }).whenComplete(() => _signingOut = false);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _wire.close();
    await _refresh?.cancel();
    await _messages?.cancel();
    await _tail;
    await _received.close();
    await _refused.close();
  }
}
