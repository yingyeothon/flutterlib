import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yingyeothon_kvstore_client/yingyeothon_kvstore_client.dart';
import 'package:yingyeothon_leaderboard_client/yingyeothon_leaderboard_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';
import 'package:yingyeothon_push_client/yingyeothon_push_client.dart';
import 'package:yingyeothon_social_client/yingyeothon_social_client.dart';

import '../game_kit.dart';
import '../kit_json.dart';
import 'emitter.dart';
part 'content_save.dart';
part 'room.dart';
part 'turns.dart';
part 'board_mail_friends.dart';
part 'match_push.dart';

/// Owns the shared identity, transports, lifecycle and purpose-shaped modules.
final class GameKitImpl implements GameKit {
  /// Creates a lazy kit without opening any connection.
  GameKitImpl(this._options)
    : _http = _options.client ?? http.Client(),
      _logger = _options.logger ?? nullLogger,
      _config = KitJson.copy(_options.config.raw)! as JsonObject,
      _mergePolicies = Map.unmodifiable(_options.mergePolicies) {
    for (final duration in [
      _options.contentInterval,
      _options.mailInterval,
      _options.matchInterval,
      _options.roomTimeout,
    ]) {
      if (duration <= Duration.zero) {
        throw ArgumentError('kit intervals must be positive');
      }
    }
    if (_options.matchInterval < const Duration(seconds: 1) ||
        _options.maxMergeRetries < 0 ||
        _options.maxLogBytes < 8192 ||
        _options.logTtlSeconds < 1) {
      throw ArgumentError('kit retry, log and polling limits are invalid');
    }
    _session =
        _options.session ??
        AuthSession(
          AuthSessionOptions(
            fetchServerTime: () {
              final state = _section('state');
              final url = _url(state, 'url', 'session');
              return KvStoreClient.fetchServerTime(
                url,
                client: _http,
                logger: _logger,
              );
            },
            signIn: _options.login,
            storage: _options.tokenStorage,
            monotonicMilliseconds: _options.monotonicMilliseconds,
            logger: _logger,
          ),
        );
    _clock.start();
    _content = _Content(this);
    _save = _Save(this);
    _room = _Room(this);
    _turns = _Turns(this);
    _mail = _Mail(this);
    _friends = _Friends(this);
    _match = _Matchmaking(this);
    _push = _Push(this);
    _identitySubscription = _session.changed.listen((_) => _identityChanged());
  }
  final GameKitOptions _options;
  final http.Client _http;
  final Logger _logger;
  final JsonObject _config;
  final Map<String, KitMerge> _mergePolicies;
  final Stopwatch _clock = Stopwatch();
  late final AuthSession _session;
  late final _Content _content;
  late final _Save _save;
  late final _Room _room;
  late final _Turns _turns;
  late final _Mail _mail;
  late final _Friends _friends;
  late final _Matchmaking _match;
  late final _Push _push;
  final Map<String, _Board> _boards = {};
  final List<_Poller> _pollers = [];
  final Emitter<KitError> _refused = Emitter<KitError>();
  late final StreamSubscription<ChannelToken?> _identitySubscription;
  KvStoreClient? _kv;
  LeaderboardClient? _lb;
  SocialClient? _social;
  GatewayPresenceClient? _presence;
  bool _foreground = true, _closed = false;
  int _generation = 0;
  int get _now =>
      _options.monotonicMilliseconds?.call() ?? _clock.elapsedMilliseconds;
  @override
  AuthSession get session => _session;
  @override
  KitContent get content => _content;
  @override
  KitSave get save => _save;
  @override
  KitRoom get room => _room;
  @override
  KitTurns get turns => _turns;
  @override
  KitBoard board(String alias) =>
      _boards.putIfAbsent(alias, () => _Board(this, alias));
  @override
  KitMail get mail => _mail;
  @override
  KitFriends get friends => _friends;
  @override
  KitMatchmaking get matchmaking => _match;
  @override
  KitPush get push => _push;
  @override
  Stream<KitError> get refused => _refused.stream;
  JsonObject _section(String name) => _config.getObject(name) ?? const {};
  Uri _url(JsonObject section, String name, String module) {
    final raw = section.getString(name);
    final url = raw == null ? null : Uri.tryParse(raw);
    if (url == null ||
        !['http', 'https', 'ws', 'wss'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.hasFragment ||
        url.hasQuery ||
        url.userInfo.isNotEmpty) {
      throw KitError(module, 'not_configured');
    }
    return url;
  }

  String _required(JsonObject object, String name, String module) {
    final value = object.getString(name);
    if (value == null || value.isEmpty) {
      throw KitError(module, 'not_configured');
    }
    return value;
  }

  String _credential(String module) {
    if (_closed) throw KitError(module, 'invalid_state');
    final token = _session.token;
    if (token == null) throw KitError(module, 'signed_out');
    return token;
  }

  KvCollection _collection(String alias) {
    final name = _required(_section('collections'), alias, alias);
    final token = _credential(alias);
    _kv ??= KvStoreClient(
      KvStoreClientOptions(
        baseUrl: _url(_section('state'), 'url', alias),
        token: token,
        client: _http,
        logger: _logger,
      ),
    );
    return _kv!.collection(name);
  }

  Leaderboard _board(String alias) {
    final name = _required(_section('boards'), alias, 'board');
    final token = _credential('board');
    _lb ??= LeaderboardClient(
      LeaderboardClientOptions(
        baseUrl: _url(_section('state'), 'url', 'board'),
        token: token,
        client: _http,
        logger: _logger,
      ),
    );
    return _lb!.board(name);
  }

  SocialClient _socialClient() {
    final token = _credential('friends');
    return _social ??= SocialClient(
      SocialClientOptions(
        baseUrl: _url(_section('state'), 'url', 'friends'),
        token: token,
        client: _http,
        logger: _logger,
      ),
    );
  }

  GatewayPresenceClient _presenceClient() {
    final token = _credential('friends');
    final gateway = _section('gateway');
    final origin = _url(gateway, 'url', 'friends');
    return _presence ??= GatewayPresenceClient(
      GatewayPresenceClientOptions(
        baseUrl: origin.replace(
          scheme: origin.scheme == 'wss'
              ? 'https'
              : origin.scheme == 'ws'
              ? 'http'
              : origin.scheme,
        ),
        channelId: _required(gateway, 'lobbyChannelId', 'friends'),
        token: token,
        client: _http,
        logger: _logger,
      ),
    );
  }

  void _guard(int generation, String module) {
    if (_closed || generation != _generation || _session.token == null) {
      throw KitError(module, 'signed_out');
    }
  }

  Future<T> _run<T>(String module, Future<T> Function() action) async {
    final generation = _generation;
    _credential(module);
    try {
      final value = await action();
      _guard(generation, module);
      return value;
    } on KitError {
      rethrow;
    } on ArgumentError {
      rethrow;
    } catch (error) {
      final failure = _map(module, error);
      if (failure.code == 'signed_out' &&
          generation == _generation &&
          _session.token != null) {
        try {
          await _session.signOut();
        } on Exception {
          /* identity is already stopped */
        }
      }
      throw failure;
    }
  }

  KitError _map(String module, Object error) {
    if (error is KitError) return error;
    int? status;
    String? reason, code;
    if (error is KvStoreException) {
      status = error.status;
      reason = error.reason;
      code = error.code;
    }
    if (error is LeaderboardException) {
      status = error.status;
      reason = error.reason;
      code = error.code;
    }
    if (error is SocialException) {
      status = error.status;
      reason = error.reason;
      code = error.code;
    }
    if (error is MatchException) {
      status = error.status;
      reason = error.reason;
      code = error.code;
    }
    if (error is PushException) {
      status = error.status;
      reason = error.reason;
      code = error.code;
    }
    if (error is AuthSessionException) {
      return KitError(
        module,
        error.code,
        retryable: error.code == 'unavailable',
      );
    }
    if (error is GatewayClientException) code = error.code.wire;
    if (status == 401) return KitError(module, 'signed_out', status: status);
    if (status == 403) return KitError(module, 'forbidden', status: status);
    if (status == 410) {
      return KitError(module, 'channel_inactive', status: status);
    }
    if (reason == 'out_of_range') return KitError(module, 'out_of_range');
    if (reason == 'cooldown') {
      return KitError(module, 'cooldown', retryable: true, status: status);
    }
    if (['proposal_closed', 'not_proposed'].contains(reason)) {
      return KitError(module, 'proposal_closed');
    }
    if (['proposed', 'confirmed'].contains(reason)) {
      return KitError(module, 'proposed');
    }
    if (module == 'push' &&
        (status == 409 ||
            (status == 400 &&
                [
                  'push_project_required',
                  'push_project_refused',
                ].contains(code)))) {
      return KitError(module, 'push_refused');
    }
    if (status == 429 || code == 'rate_limited') {
      return KitError(module, 'rate_limited', retryable: true, status: status);
    }
    if (status == 409) {
      return KitError(module, 'conflict', retryable: true, status: status);
    }
    if (code == 'unknown_user') {
      return KitError(module, 'offline', retryable: true);
    }
    if (code == 'too_long') return KitError(module, 'payload_too_large');
    if (code == 'cancelled') return KitError(module, 'cancelled');
    if (error is StateError || error is GatewayClientException) {
      return KitError(module, 'invalid_state');
    }
    return KitError(module, 'unavailable', retryable: true, status: status);
  }

  void _background(String module, Future<void> operation) {
    final generation = _generation;
    unawaited(
      operation.catchError((Object error) {
        final failure = _map(module, error);
        if (!_closed &&
            generation == _generation &&
            failure.code != 'cancelled') {
          _refused.emit(failure);
        }
      }),
    );
  }

  String _randomId() => base64Url
      .encode(List.generate(16, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  void _identityChanged() {
    _generation++;
    _kv?.close();
    _lb?.close();
    _social?.close();
    _presence?.close();
    _kv = null;
    _lb = null;
    _social = null;
    _presence = null;
    _content._reset();
    _save._reset();
    _mail._reset();
    _friends._reset();
    _room._reset();
    _turns._reset();
    _match._reset();
    _push._reset();
    for (final board in _boards.values) {
      board._info = null;
    }
    for (final poller in _pollers) {
      poller.wake();
    }
  }

  @override
  void setForeground(bool foreground) {
    if (_closed) throw const KitError('kit', 'invalid_state');
    if (_foreground == foreground) return;
    _foreground = foreground;
    for (final poller in _pollers) {
      if (foreground) {
        poller.wake();
      } else {
        poller.stop();
      }
    }
    _room._foregroundChanged();
    _match._foregroundChanged();
    if (foreground && _session.token != null) {
      _background('session', _session.synchronize());
      _background('save', _save.flush());
      _turns._foregroundChanged();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _match._reset();
    _turns._reset();
    _room._reset();
    for (final poller in _pollers) {
      poller.stop();
    }
    final subscriptionClosed = _identitySubscription.cancel();
    final sessionClosed = _options.session == null
        ? _session.close()
        : Future<void>.value();
    await subscriptionClosed;
    await _turns._close();
    await _room._close();
    await _match._close();
    await _push._close();
    await _content._close();
    await _mail._close();
    await _friends._close();
    _kv?.close();
    _lb?.close();
    _social?.close();
    _presence?.close();
    await sessionClosed;
    if (_options.client == null) _http.close();
    _clock.stop();
    await _refused.close();
  }
}

final class _Poller {
  _Poller(this.kit, this.module, this.interval, this.action, this.interested) {
    kit._pollers.add(this);
  }
  final GameKitImpl kit;
  final String module;
  final Duration interval;
  final Future<void> Function() action;
  final bool Function() interested;
  Timer? _timer;
  bool _busy = false, _again = false;
  bool get _enabled =>
      !kit._closed &&
      kit._foreground &&
      kit.session.token != null &&
      interested();
  void stop() {
    _timer?.cancel();
    _timer = null;
    _again = false;
  }

  void wake() {
    stop();
    if (!_enabled) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    kit._background(
      module,
      Future<void>.sync(action).whenComplete(() {
        _busy = false;
        if (!_enabled) return;
        if (_again) {
          _again = false;
          wake();
        } else {
          _timer = Timer(interval, wake);
        }
      }),
    );
  }
}
