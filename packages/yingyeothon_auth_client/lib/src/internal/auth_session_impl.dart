import 'dart:async';
import 'dart:convert';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import '../auth_client.dart';
import '../auth_session.dart';
import 'emitter.dart';

/// Engine-free session implementation with generation-safe asynchronous work.
final class AuthSessionImpl implements AuthSession {
  /// Copies options and starts the monotonic clock.
  AuthSessionImpl(this._options) : _logger = _options.logger ?? nullLogger {
    _stopwatch.start();
  }
  final AuthSessionOptions _options;
  final Logger _logger;
  final Stopwatch _stopwatch = Stopwatch();
  final Emitter<ChannelToken?> _changed = Emitter<ChannelToken?>();
  final Emitter<void> _expiring = Emitter<void>();
  final Emitter<void> _signedOut = Emitter<void>();
  ChannelToken? _identity;
  ({int epoch, int monotonic})? _anchor;
  Timer? _expiry, _warning;
  bool _warned = false;
  bool _closed = false;
  int _generation = 0;
  Future<void> _storageTail = Future.value();
  Future<void>? _sync;
  int get _monotonic =>
      _options.monotonicMilliseconds?.call() ?? _stopwatch.elapsedMilliseconds;
  @override
  String? get token => _identity?.jwt;
  @override
  String? get userId => _identity?.userId;
  @override
  int? get expiresAt => _identity?.exp;
  @override
  Stream<ChannelToken?> get changed => _changed.stream;
  @override
  Stream<void> get expiring => _expiring.stream;
  @override
  Stream<void> get signedOut => _signedOut.stream;
  void _check() {
    if (_closed) throw const AuthSessionException('invalid_state');
  }

  Future<void> _storage(Future<void> Function() operation) {
    final task = _storageTail.then((_) => operation());
    _storageTail = task.then<void>((_) {}, onError: (Object _) {});
    return task.catchError((Object _) {
      throw const AuthSessionException('unavailable');
    });
  }

  @override
  Future<ChannelToken> fromToken(String jwt) async {
    _check();
    final identity = _claims(jwt);
    final generation = ++_generation;
    _sync = null;
    _clearTimers();
    _identity = identity;
    _warned = false;
    _changed.emit(identity);
    if (generation != _generation || _closed) {
      throw const AuthSessionException('signed_out');
    }
    if (_options.storage != null) {
      try {
        await _storage(() {
          if (generation != _generation || _closed) {
            throw const AuthSessionException('signed_out');
          }
          return _options.storage!.store(jwt);
        });
      } catch (_) {
        if (generation == _generation && !_closed) {
          _generation++;
          _clearTimers();
          _identity = null;
          _changed.emit(null);
          _signedOut.emit(null);
        }
        rethrow;
      }
    }
    if (generation != _generation || _closed) {
      throw const AuthSessionException('signed_out');
    }
    try {
      await synchronize();
    } on AuthSessionException {
      _logger.warn('session clock unavailable');
    }
    if (generation != _generation || _closed) {
      throw const AuthSessionException('signed_out');
    }
    _arm();
    return identity;
  }

  ChannelToken _claims(String jwt) {
    if (jwt.length > 8192 || jwt.codeUnits.any((c) => c < 33 || c > 126)) {
      throw ArgumentError('JWT must be bounded printable ASCII');
    }
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) throw const FormatException();
      final decoded = Json.tryDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      final value = decoded is JsonDecoded ? decoded.value : null;
      if (value is! JsonObject) throw const FormatException();
      final sub = value.getString('sub');
      final exp = value.getInt('exp');
      if (sub == null ||
          sub.isEmpty ||
          sub.length > 128 ||
          sub.codeUnits.any((c) => c < 33 || c > 126) ||
          exp == null) {
        throw const FormatException();
      }
      return ChannelToken(jwt: jwt, userId: sub, exp: exp);
    } on Exception {
      throw ArgumentError('JWT must contain valid identity and expiry claims');
    }
  }

  @override
  Future<ChannelToken> signIn() async {
    _check();
    final login = _options.signIn;
    if (login == null) throw const AuthSessionException('invalid_state');
    final generation = _generation;
    try {
      final identity = await login();
      if (generation != _generation || _closed) {
        throw const AuthSessionException('cancelled');
      }
      return await fromToken(identity.jwt);
    } on AuthSessionException {
      rethrow;
    } catch (_) {
      throw const AuthSessionException('unavailable');
    }
  }

  @override
  Future<ChannelToken?> restore() async {
    _check();
    if (_options.storage == null) return null;
    final generation = _generation;
    String? jwt;
    try {
      jwt = await _options.storage!.load();
    } catch (_) {
      throw const AuthSessionException('unavailable');
    }
    if (generation != _generation || _closed) {
      throw const AuthSessionException('cancelled');
    }
    return jwt == null ? null : fromToken(jwt);
  }

  @override
  int now() {
    _check();
    final anchor = _anchor;
    if (anchor == null) throw const AuthSessionException('unavailable');
    return anchor.epoch + _monotonic - anchor.monotonic;
  }

  @override
  Future<void> synchronize() {
    _check();
    if (_sync != null) return _sync!;
    final generation = _generation, start = _monotonic;
    final task = Future<DateTime>.sync(_options.fetchServerTime).then<void>(
      (time) {
        if (_closed || generation != _generation) return;
        _anchor = (
          epoch: time.millisecondsSinceEpoch,
          monotonic: (start + _monotonic) ~/ 2,
        );
        _arm();
      },
      onError: (Object _) {
        throw const AuthSessionException('unavailable');
      },
    );
    _sync = task;
    return task.whenComplete(() {
      if (identical(_sync, task)) _sync = null;
    });
  }

  void _clearTimers() {
    _warning?.cancel();
    _expiry?.cancel();
    _warning = null;
    _expiry = null;
  }

  void _arm() {
    _clearTimers();
    if (_identity == null || _anchor == null || _closed) return;
    final remaining = _identity!.exp * 1000 - now();
    if (remaining <= 0) {
      unawaited(signOut().catchError((Object _) {}));
      return;
    }
    final generation = _generation;
    // Re-arm long browser deadlines before the platform timer's 32-bit ceiling.
    const maxDelay = 86400000;
    _expiry = Timer(Duration(milliseconds: remaining.clamp(1, maxDelay)), () {
      if (generation == _generation) _arm();
    });
    if (!_warned) {
      final delay = (remaining - 600000).clamp(0, maxDelay);
      _warning = Timer(Duration(milliseconds: delay), () {
        if (_closed || generation != _generation) return;
        if (_identity!.exp * 1000 - now() <= 600000) {
          _warned = true;
          _expiring.emit(null);
        } else {
          _arm();
        }
      });
    }
  }

  @override
  Future<void> signOut() {
    _check();
    final hadIdentity = _identity != null;
    _generation++;
    _identity = null;
    _sync = null;
    _clearTimers();
    if (hadIdentity) {
      _changed.emit(null);
      _signedOut.emit(null);
    }
    return _options.storage == null
        ? Future.value()
        : _storage(_options.storage!.clear);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _clearTimers();
    final hadIdentity = _identity != null;
    _identity = null;
    _sync = null;
    if (hadIdentity) _changed.emit(null);
    _stopwatch.stop();
    await _changed.close();
    await _expiring.close();
    await _signedOut.close();
  }
}
