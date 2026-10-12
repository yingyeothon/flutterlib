part of 'game_kit_impl.dart';

final class _Matchmaking implements KitMatchmaking {
  _Matchmaking(this.kit) {
    _poller = _Poller(
      kit,
      'matchmaking',
      kit._options.matchInterval,
      _poll,
      () => _polling,
    );
  }
  final GameKitImpl kit;
  final Emitter<KitMatchStatus> _changes = Emitter<KitMatchStatus>();
  late final _Poller _poller;
  LiveMatchClient? _live;
  DeferredMatchClient? _deferred;
  bool _polling = false;
  String? _lastStatus;
  int? _lastRequest;
  int _epoch = 0;
  bool _interested = false;
  Future<void> _lane = Future.value();
  final Map<Timer, Completer<void>> _waits = {};
  StreamSubscription<KitInvitation>? _formationInvites;
  bool _forming = false;
  Completer<void>? _formationDone;
  Object? _findId;
  JsonObject get _config => kit._section('match');
  bool get _isDeferred => _config['mode'] == 'deferred';
  DeferredMatchClient get _wire {
    if (!_isDeferred) throw const KitError('matchmaking', 'invalid_state');
    final token = kit._credential('matchmaking');
    return _deferred ??= DeferredMatchClient(
      DeferredMatchClientOptions(
        apiBase: kit._url(_config, 'apiBase', 'matchmaking'),
        channelId: kit._required(_config, 'channelId', 'matchmaking'),
        token: token,
        ticketUrl: Uri.tryParse(
          kit._required(_config, 'ticketUrl', 'matchmaking'),
        ),
        client: kit._http,
        logger: kit._logger,
      ),
    );
  }

  @override
  Stream<KitMatchStatus> get stateChanged => _changes.stream;
  KitMatch _result(MatchResult result, {bool? partial}) => KitMatch(
    matchId: result.matchId,
    members: result.members.map((m) => m.userId).toList(),
    partial: partial ?? result.partial,
    result: KitJson.copy(result.result),
  );
  KitMatchStatus _ticket(MatchTicket ticket) {
    final status = KitMatchStatus(
      state: ticket.state,
      matchId: ticket.matchId,
      acceptBy: ticket.acceptBy,
      accepted: ticket.accepted,
      match: ticket.confirmed == null ? null : _result(ticket.confirmed!),
    );
    final text = KitJson.canonical(ticket.raw);
    if (_lastStatus != text) {
      _lastStatus = text;
      _changes.emit(status);
    }
    if (['confirmed', 'expired', 'declined', 'failed'].contains(ticket.state)) {
      _polling = false;
      _poller.stop();
    }
    return status;
  }

  Future<void> _wait(Duration duration) {
    if (duration <= Duration.zero) return Future.value();
    final completer = Completer<void>();
    late final Timer timer;
    timer = Timer(duration, () => completer.complete());
    _waits[timer] = completer;
    return completer.future.whenComplete(() => _waits.remove(timer));
  }

  void _guard(int generation, int epoch) {
    kit._guard(generation, 'matchmaking');
    if (epoch != _epoch) throw const KitError('matchmaking', 'cancelled');
    if (!kit._foreground) throw const KitError('matchmaking', 'invalid_state');
  }

  Future<T> _attempt<T>(
    int generation,
    int epoch,
    Future<T> Function(DeferredMatchClient) action,
  ) {
    final task = _lane.then<T>((_) async {
      _guard(generation, epoch);
      final remaining = 1000 - (kit._now - (_lastRequest ?? -1000));
      if (remaining > 0) await _wait(Duration(milliseconds: remaining));
      _guard(generation, epoch);
      _lastRequest = kit._now;
      final result = await action(_wire);
      _guard(generation, epoch);
      return result;
    });
    _lane = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  Future<T> _request<T>(Future<T> Function(DeferredMatchClient) action) async {
    final generation = kit._generation, epoch = _epoch;
    _interested = true;
    var retry = 0;
    for (;;) {
      _guard(generation, epoch);
      try {
        return await _attempt(generation, epoch, action);
      } on MatchException catch (error) {
        _guard(generation, epoch);
        final reason = error.reason;
        Duration? delay;
        if (error.status == 429 && reason == 'cooldown') {
          delay = error.retryAfter ?? const Duration(seconds: 1);
        } else if (error.status == 409 && reason == 'confirming') {
          delay = const Duration(milliseconds: 1500);
        } else if (error.status == 429 ||
            error.status == 503 ||
            (error.status == 0 && error.code == 'network')) {
          delay = Duration(seconds: (1 << retry.clamp(0, 5)).clamp(1, 30));
          retry++;
        }
        if (delay == null) {
          final failure = kit._map('matchmaking', error);
          if (failure.code == 'signed_out' &&
              kit.session.token != null &&
              generation == kit._generation) {
            await kit.session.signOut();
          }
          throw failure;
        }
        await _wait(delay);
      }
    }
  }

  void _cancelWaits() {
    _epoch++;
    for (final entry in _waits.entries.toList()) {
      entry.key.cancel();
      if (!entry.value.isCompleted) {
        entry.value.completeError(const KitError('matchmaking', 'cancelled'));
      }
    }
    _waits.clear();
  }

  void _foregroundChanged() {
    if (!kit._foreground) {
      _cancelWaits();
    } else if (_interested && _isDeferred && kit.session.token != null) {
      _polling = true;
      _poller.wake();
    }
  }

  @override
  Future<KitMatchStatus> submit() async {
    try {
      final ticket = await _request((wire) => wire.submit());
      _polling = true;
      final result = _ticket(ticket);
      _poller.wake();
      return result;
    } on KitError catch (e) {
      if (e.code == 'proposed') {
        final current = await status();
        if (current != null) {
          _polling = true;
          _poller.wake();
          return current;
        }
      }
      rethrow;
    }
  }

  @override
  Future<KitMatchStatus?> status() async {
    final ticket = await _request((wire) => wire.status());
    if (ticket == null) {
      _polling = false;
      _poller.stop();
      return null;
    }
    final startPolling =
        !_polling && ['waiting', 'proposed'].contains(ticket.state);
    if (startPolling) _polling = true;
    final result = _ticket(ticket);
    if (startPolling) scheduleMicrotask(_poller.wake);
    return result;
  }

  @override
  Future<KitMatchStatus> accept() async {
    try {
      return _ticket(await _request((wire) => wire.accept()));
    } on KitError catch (e) {
      if (['proposal_closed', 'proposed'].contains(e.code)) {
        final current = await status();
        if (current != null) return current;
      }
      rethrow;
    }
  }

  @override
  Future<KitMatchStatus> decline() async {
    try {
      return _ticket(await _request((wire) => wire.decline()));
    } on KitError catch (e) {
      if (['proposal_closed', 'proposed'].contains(e.code)) {
        final current = await status();
        if (current != null) return current;
      }
      rethrow;
    }
  }

  @override
  Future<void> cancel() async {
    if (_isDeferred) {
      _polling = false;
      _poller.stop();
      _cancelWaits();
      await _request((wire) => wire.cancel());
      _interested = false;
      _polling = false;
      _poller.stop();
    } else {
      _live?.cancel();
      _forming = false;
      if (_formationDone != null && !_formationDone!.isCompleted) {
        _formationDone!.completeError(
          const KitError('matchmaking', 'cancelled'),
        );
      }
      await _formationInvites?.cancel();
    }
  }

  Future<void> _poll() async {
    await status();
  }

  void _wake(MatchPush push) {
    if (push.channelId == _config.getString('channelId') && _isDeferred) {
      _interested = true;
      _polling = true;
      _poller.wake();
    }
  }

  @override
  Future<KitMatch> find({
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (_config.isEmpty) throw const KitError('matchmaking', 'not_configured');
    if (_isDeferred) throw const KitError('matchmaking', 'invalid_state');
    if (timeout <= Duration.zero) {
      throw ArgumentError('find timeout must be positive');
    }
    if (kit._room._lobby?.state != GatewayClientState.connected) {
      throw const KitError('matchmaking', 'lobby_required');
    }
    if (_forming) throw const KitError('matchmaking', 'invalid_state');
    final generation = kit._generation, findId = Object();

    bool current() =>
        !kit._closed &&
        generation == kit._generation &&
        identical(_findId, findId) &&
        _forming;
    final old = _live;
    if (old != null) unawaited(old.close());
    final live = LiveMatchClient(
      LiveMatchClientOptions(
        url: kit._url(_config, 'url', 'matchmaking'),
        channelId: kit._required(_config, 'channelId', 'matchmaking'),
        token: kit._credential('matchmaking'),
        webSocketFactory: kit._options.webSocketFactory,
        logger: kit._logger,
        timeout: timeout,
      ),
    );
    _live = live;
    _findId = findId;
    _forming = true;
    final early = <KitInvitation>[];
    Set<String>? matchedMembers;
    final invitations = kit._room.invited.listen((invite) {
      if (!current()) return;
      if (matchedMembers == null) {
        early.add(invite);
      } else if (matchedMembers.contains(invite.from)) {
        kit._background('matchmaking', invite.accept());
      }
    });
    _formationInvites = invitations;
    StreamSubscription<void>? roster;
    Timer? deadline;
    Completer<void>? completed;
    try {
      final result = await kit._run('matchmaking', live.find);
      if (!current()) throw const KitError('matchmaking', 'cancelled');
      if (kit._options.matchCallback) return _result(result);
      final members = result.members.map((m) => m.userId).toSet();
      if (!members.contains(kit.session.userId) || members.isEmpty) {
        throw const KitError('matchmaking', 'invalid_state');
      }
      matchedMembers = members;
      final leader = (members.toList()..sort()).first;
      final done = Completer<void>();
      completed = done;
      _formationDone = done;
      unawaited(done.future.then<void>((_) {}, onError: (Object _) {}));
      deadline = Timer(const Duration(seconds: 30), () {
        if (!done.isCompleted) done.complete();
      });
      bool complete() =>
          kit.room.id != null &&
          members.every((id) => kit.room.members.any((m) => m.userId == id));
      roster = kit._room._rosterChanged.stream.listen((_) {
        if (current() && complete() && !done.isCompleted) done.complete();
      });
      for (final invite in early) {
        if (members.contains(invite.from)) {
          kit._background('matchmaking', invite.accept());
        }
      }
      if (kit.session.userId == leader) {
        await kit.room.create();
        for (final member in members) {
          if (!current()) throw const KitError('matchmaking', 'cancelled');
          if (member != leader) await kit.room.invite(member);
        }
      }
      if (complete() && !done.isCompleted) done.complete();
      await done.future;
      kit._guard(generation, 'matchmaking');
      if (!current()) throw const KitError('matchmaking', 'cancelled');
      final partial = !complete();
      return KitMatch(
        matchId: result.matchId,
        partial: result.partial || partial,
        result: KitJson.copy(result.result),
        members: result.members
            .where(
              (m) =>
                  !partial || kit.room.members.any((r) => r.userId == m.userId),
            )
            .map((m) => m.userId)
            .toList(),
      );
    } finally {
      deadline?.cancel();
      if (roster != null) unawaited(roster.cancel());
      unawaited(invitations.cancel());
      if (identical(_findId, findId)) {
        _findId = null;
        _forming = false;
        if (identical(_formationInvites, invitations)) _formationInvites = null;
        if (identical(_formationDone, completed)) _formationDone = null;
      }
    }
  }

  void _reset() {
    _polling = false;
    _lastStatus = null;
    _lastRequest = null;
    _interested = false;
    _cancelWaits();
    _poller.stop();
    _forming = false;
    _findId = null;
    if (_formationDone != null && !_formationDone!.isCompleted) {
      _formationDone!.completeError(const KitError('matchmaking', 'cancelled'));
    }
    _formationDone = null;
    _deferred?.close();
    _deferred = null;
    final live = _live;
    _live = null;
    if (live != null) kit._background('matchmaking', live.close());
    for (final entry in _waits.entries.toList()) {
      entry.key.cancel();
      if (!entry.value.isCompleted) {
        entry.value.completeError(const KitError('matchmaking', 'cancelled'));
      }
    }
    _waits.clear();
  }

  Future<void> _close() async {
    _reset();
    await _formationInvites?.cancel();
    await _changes.close();
  }
}

final class _Push implements KitPush {
  _Push(this.kit);
  final GameKitImpl kit;
  PushClient? _client;
  Future<void> _cleanupTail = Future.value();
  // Canceled by _cleanup on reset and close.
  // ignore: cancel_subscriptions
  StreamSubscription<ClassifiedPush>? _messages;
  // Canceled by _cleanup on reset and close.
  // ignore: cancel_subscriptions
  StreamSubscription<PushException>? _errors;
  final Emitter<KitMessage> _received = Emitter<KitMessage>();
  PushClient get _wire {
    if (_client != null) return _client!;
    final config = kit._section('push');
    final token = kit._credential('push');
    final project = kit._options.firebaseProject;
    if (project == null || project.isEmpty) {
      throw const KitError('push', 'not_configured');
    }
    final client = PushClient(
      PushClientOptions(
        apiBase: kit._url(config, 'apiBase', 'push'),
        channelId: kit._required(config, 'channelId', 'push'),
        token: token,
        topic: kit._required(config, 'topic', 'push'),
        project: project,
        messaging: kit._options.pushMessaging,
        client: kit._http,
        logger: kit._logger,
      ),
    );
    _client = client;
    _messages = client.received.listen((message) {
      if (_client != client || kit._closed) return;
      _received.emit(
        KitMessage(
          data: message.message.data,
          matchWake: message is MatchPush,
          title: message.message.title,
          body: message.message.body,
        ),
      );
      if (message is MatchPush) kit._match._wake(message);
    });
    _errors = client.refused.listen((error) {
      if (_client != client || kit._closed) return;
      if (error.status == 401) {
        kit._background('session', kit.session.signOut());
      } else {
        kit._refused.emit(kit._map('push', error));
      }
    });
    return client;
  }

  @override
  Stream<KitMessage> get received => _received.stream;
  @override
  Future<void> start() {
    final generation = kit._generation;
    return kit._run('push', () async {
      await _cleanupTail;
      kit._guard(generation, 'push');
      await _wire.start();
    });
  }

  @override
  Future<void> register(String deviceToken) {
    final generation = kit._generation;
    return kit._run('push', () async {
      await _cleanupTail;
      kit._guard(generation, 'push');
      await _wire.register(deviceToken);
    });
  }

  @override
  Future<void> unregister() => kit._run('push', _wire.unregister);
  void _reset() {
    final client = _client;
    _client = null;
    if (client != null) {
      final messages = _messages, errors = _errors;
      _cleanupTail = _cleanupTail.then(
        (_) => _cleanup(client, messages, errors),
      );
      kit._background('push', _cleanupTail);
    }
    _messages = null;
    _errors = null;
  }

  Future<void> _cleanup(
    PushClient client,
    StreamSubscription<ClassifiedPush>? messages,
    StreamSubscription<PushException>? errors,
  ) async {
    await messages?.cancel();
    await errors?.cancel();
    try {
      await client.unregister();
    } on Exception {
      /* stopping a dead JWT is still final */
    } finally {
      await client.close();
    }
  }

  Future<void> _close() async {
    final client = _client;
    _client = null;
    await _cleanupTail;
    if (client != null) await _cleanup(client, _messages, _errors);
    await _received.close();
  }
}
