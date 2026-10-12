part of 'game_kit_impl.dart';

final class _Room implements KitRoom {
  _Room(this.kit) : _senderSession = kit._randomId();
  final GameKitImpl kit;
  final String _senderSession;
  int _sequence = 0, _revision = 0, _receivedRevision = -1;
  String? _stateSender;
  GatewayLobbyClient? _lobby;
  Future<void>? _connecting;
  int _connectionEpoch = 0;
  PartyFrame? _roster;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Emitter<KitInvitation> _invited = Emitter<KitInvitation>();
  final Emitter<KitMember> _joined = Emitter<KitMember>(),
      _left = Emitter<KitMember>(),
      _online = Emitter<KitMember>();
  final Emitter<String> _hostChanged = Emitter<String>();
  final Emitter<Object?> _becameHost = Emitter<Object?>(),
      _state = Emitter<Object?>();
  final Emitter<KitRoomEvent> _events = Emitter<KitRoomEvent>(),
      _control = Emitter<KitRoomEvent>();
  final Emitter<void> _rosterChanged = Emitter<void>();
  final Map<String, int> _seen = {};
  Object? _lastState;
  bool _hasState = false, _interested = false;
  Future<void> _lane = Future.value();
  Completer<void>? _ack;
  Completer<void>? _firstRoster;
  bool Function()? _checkAck;
  @override
  String? get id => _roster?.partyId;
  @override
  String? get host => id == null ? null : _roster?.leaderId;
  @override
  bool get isHost => host != null && host == kit.session.userId;
  @override
  List<KitMember> get members => List.unmodifiable(
    _roster?.members.map((m) => KitMember(m.userId, m.online)) ??
        const <KitMember>[],
  );
  @override
  Stream<KitInvitation> get invited {
    _interested = true;
    kit._background('room', _connect());
    return _invited.stream;
  }

  @override
  Stream<KitMember> get memberJoined => _joined.stream;
  @override
  Stream<KitMember> get memberLeft => _left.stream;
  @override
  Stream<KitMember> get memberOnline => _online.stream;
  @override
  Stream<String> get hostChanged => _hostChanged.stream;
  @override
  Stream<Object?> get becameHost => _becameHost.stream;
  @override
  Stream<KitRoomEvent> get events => _events.stream;
  @override
  Stream<Object?> get state => _state.stream;
  @override
  Future<void> connect() => _connect();
  Future<void> _connect() {
    _interested = true;
    if (_connecting != null) return _connecting!;
    final generation = kit._generation, epoch = _connectionEpoch;
    final task = Future<void>.microtask(() => _open(generation, epoch));
    _connecting = task;
    return task.whenComplete(() {
      if (identical(_connecting, task)) _connecting = null;
    });
  }

  Future<void> _open(int generation, int epoch) async {
    kit._guard(generation, 'room');
    kit._credential('room');
    if (!kit._foreground) throw const KitError('room', 'invalid_state');
    if (_lobby?.state == GatewayClientState.connected) return;
    if (_lobby != null) await _disconnect(clearConnecting: false);
    kit._guard(generation, 'room');
    if (epoch != _connectionEpoch || !kit._foreground) {
      throw const KitError('room', 'cancelled');
    }
    final config = kit._section('gateway');
    final options = GatewayLobbyClientOptions(
      url: kit._url(config, 'url', 'room').toString(),
      channelId: kit._required(config, 'lobbyChannelId', 'room'),
      token: kit._credential('room'),
      webSocketFactory: kit._options.webSocketFactory,
      logger: kit._logger,
    );
    late final GatewayLobbyClient lobby;
    try {
      lobby = (kit._options.lobbyFactory ?? GatewayLobbyClient.new)(options);
    } catch (_) {
      throw const KitError('room', 'unavailable', retryable: true);
    }
    _lobby = lobby;
    final firstRoster = Completer<void>();
    _firstRoster = firstRoster;
    unawaited(firstRoster.future.then<void>((_) {}, onError: (Object _) {}));
    _subscriptions.add(
      lobby.partyChanged.listen((frame) {
        if (_lobby == lobby) {
          _applyRoster(frame);
          if (!firstRoster.isCompleted) firstRoster.complete();
        }
      }),
    );
    _subscriptions.add(
      lobby.partyInvited.listen((frame) {
        if (_lobby == lobby) {
          _invited.emit(_Invitation(this, frame.partyId, frame.from));
        }
      }),
    );
    _subscriptions.add(
      lobby.eventReceived.listen((frame) {
        if (_lobby == lobby) _receive(frame);
      }),
    );
    _subscriptions.add(
      lobby.refused.listen((frame) {
        if (_lobby != lobby) return;
        final code = frame.code;
        final error = KitError(
          'room',
          code == 'unknown_user'
              ? 'offline'
              : code == 'rate_limited'
              ? 'rate_limited'
              : code == 'too_long'
              ? 'payload_too_large'
              : 'invalid_state',
          retryable: code == 'unknown_user' || code == 'rate_limited',
        );
        if (_ack != null && !_ack!.isCompleted) _ack!.completeError(error);
        kit._refused.emit(error);
      }),
    );
    _subscriptions.add(
      lobby.connected.listen((_) {
        if (_lobby == lobby && id != null) {
          if (!isHost) kit._background('room', resync());
          kit._turns._connected();
        }
      }),
    );
    _subscriptions.add(
      lobby.stopped.listen((_) {
        if (_lobby != lobby) return;
        if (_ack != null && !_ack!.isCompleted) {
          _ack!.completeError(
            const KitError('room', 'unavailable', retryable: true),
          );
        }
      }),
    );
    try {
      await kit._run('room', () => lobby.connect());
      // party.list runs after Hub.Join restores Redis membership, including
      // when hello had no in-memory party id yet.
      lobby.party.list();
      await firstRoster.future.timeout(
        kit._options.roomTimeout,
        onTimeout: () =>
            throw const KitError('room', 'unavailable', retryable: true),
      );
    } finally {
      if (identical(_firstRoster, firstRoster)) _firstRoster = null;
    }
    kit._guard(generation, 'room');
    if (epoch != _connectionEpoch || _lobby != lobby) {
      throw const KitError('room', 'cancelled');
    }
  }

  void _applyRoster(PartyFrame frame) {
    final previous = _roster;
    if (previous?.partyId != frame.partyId) {
      _lastState = null;
      _hasState = false;
      _seen.clear();
      _receivedRevision = -1;
    }
    _roster = frame;
    final old = previous?.members ?? const <PartyMember>[];
    for (final member in frame.members) {
      final before = old.where((m) => m.userId == member.userId).firstOrNull;
      if (before == null) {
        _joined.emit(KitMember(member.userId, member.online));
      } else if (before.online != member.online) {
        _online.emit(KitMember(member.userId, member.online));
      }
    }
    for (final member in old) {
      if (!frame.members.any((m) => m.userId == member.userId)) {
        _left.emit(KitMember(member.userId, member.online));
      }
    }
    if (previous?.leaderId != frame.leaderId && frame.leaderId.isNotEmpty) {
      _receivedRevision = -1;
      _revision = 0;
      _stateSender = null;
      _hostChanged.emit(frame.leaderId);
      if (isHost) {
        _becameHost.emit(KitJson.copy(_lastState));
      } else {
        kit._background('room', resync());
      }
    }
    if (_ack != null && !_ack!.isCompleted && _checkAck?.call() == true) {
      _ack!.complete();
    }
    _rosterChanged.emit(null);
  }

  Future<void> _command(
    bool Function() satisfied,
    void Function(GatewayLobbyClient) send,
  ) {
    final generation = kit._generation;
    final task = _lane.then<void>((_) async {
      kit._guard(generation, 'room');
      await _connect();
      kit._guard(generation, 'room');
      if (satisfied()) return;
      final ack = Completer<void>();
      _ack = ack;
      _checkAck = satisfied;
      final timer = Timer(
        kit._options.roomTimeout,
        () => ack.isCompleted
            ? null
            : ack.completeError(
                const KitError('room', 'unavailable', retryable: true),
              ),
      );
      try {
        send(_lobby!);
        await ack.future;
        kit._guard(generation, 'room');
      } catch (error) {
        throw kit._map('room', error);
      } finally {
        timer.cancel();
        if (identical(_ack, ack)) {
          _ack = null;
          _checkAck = null;
        }
      }
    });
    _lane = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  @override
  Future<void> create() =>
      _command(() => id != null && isHost, (lobby) => lobby.party.create());
  @override
  Future<void> invite(String userId) => _command(
    () =>
        _roster?.invited.contains(userId) == true ||
        members.any((m) => m.userId == userId),
    (lobby) => lobby.party.invite(userId),
  );
  @override
  Future<void> leave() =>
      _command(() => id == null, (lobby) => lobby.party.leave());
  @override
  Future<void> send(String name, Object? payload) => _send(name, payload);
  @override
  Future<void> whisper(String userId, String name, Object? payload) =>
      _send(name, payload, to: userId);
  Future<void> _send(
    String name,
    Object? payload, {
    String? to,
    bool control = false,
  }) async {
    final generation = kit._generation;
    if (!control &&
        (name.isEmpty ||
            name.startsWith('kit.') ||
            utf8.encode(name).length > 64)) {
      throw ArgumentError(
        'game event names must be nonempty, at most 64 bytes and outside the kit prefix',
      );
    }
    await _connect();
    kit._guard(generation, 'room');
    if (id == null) throw const KitError('room', 'invalid_state');
    final envelope = <String, Object?>{
      'v': 1,
      'roomId': id,
      'senderSession': _senderSession,
      'seq': ++_sequence,
      'data': KitJson.copy(payload),
    };
    if (utf8.encode(Json.encode(envelope)).length > 8192) {
      throw const KitError('room', 'payload_too_large');
    }
    try {
      _lobby!.event(
        scope: to == null ? SayScope.party : SayScope.user,
        name: name,
        payload: envelope,
        to: to,
      );
    } catch (error) {
      throw kit._map('room', error);
    }
  }

  void _receive(EventBroadcastFrame frame) {
    try {
      _receiveChecked(frame);
    } catch (_) {
      if (frame.name.startsWith('kit.turn') &&
          members.any((m) => m.userId == frame.from)) {
        kit._turns._game?._freeze();
      }
      kit._refused.emit(const KitError('room', 'invalid_state'));
    }
  }

  void _receiveChecked(EventBroadcastFrame frame) {
    final payload = frame.payload;
    if (payload is JsonObject &&
        utf8.encode(Json.encode(payload)).length > 8192) {
      kit._refused.emit(const KitError('room', 'payload_too_large'));
      return;
    }
    if (payload is! JsonObject ||
        payload['v'] != 1 ||
        payload['roomId'] != id ||
        payload.getString('senderSession') == null ||
        payload.getInt('seq') == null ||
        payload.getInt('seq')! < 1 ||
        !members.any((m) => m.userId == frame.from)) {
      return;
    }
    final sender = payload.getString('senderSession')!;
    final key = Json.encode([frame.from, sender]);
    final sequence = payload.getInt('seq')!;
    if ((_seen[key] ?? 0) >= sequence) return;
    _seen[key] = sequence;
    if (_seen.length > 1024) _seen.remove(_seen.keys.first);
    final data = payload['data'];
    if (frame.name == 'kit.state') {
      if (frame.from != host ||
          data is! JsonObject ||
          data.getInt('revision') == null ||
          data.getInt('revision')! < 0 ||
          !data.has('snapshot')) {
        return;
      }
      final revision = data.getInt('revision')!;
      if (_stateSender == sender && revision <= _receivedRevision) return;
      _stateSender = sender;
      _receivedRevision = revision;
      _lastState = KitJson.copy(data['snapshot']);
      _hasState = true;
      _state.emit(KitJson.copy(_lastState));
    } else if (frame.name == 'kit.resync') {
      if (isHost && _hasState) {
        kit._background(
          'room',
          _send(
            'kit.state',
            {'revision': _revision, 'snapshot': _lastState},
            to: frame.from,
            control: true,
          ),
        );
      }
    } else if (frame.name.startsWith('kit.')) {
      _control.emit(KitRoomEvent(frame.name, frame.from, KitJson.copy(data)));
    } else {
      _events.emit(KitRoomEvent(frame.name, frame.from, KitJson.copy(data)));
    }
  }

  @override
  Future<void> publish(Object? snapshot) async {
    if (!isHost) throw const KitError('room', 'invalid_state');
    final copy = KitJson.copy(snapshot);
    await _send('kit.state', {
      'revision': ++_revision,
      'snapshot': copy,
    }, control: true);
    _lastState = copy;
    _hasState = true;
  }

  @override
  Future<void> resync() async {
    if (id == null || isHost || host == null) return;
    _receivedRevision = -1;
    await _send('kit.resync', null, to: host, control: true);
  }

  Future<void> _disconnect({bool clearConnecting = true}) async {
    final lobby = _lobby;
    _lobby = null;
    final firstRoster = _firstRoster;
    _firstRoster = null;
    if (firstRoster != null && !firstRoster.isCompleted) {
      firstRoster.completeError(const KitError('room', 'cancelled'));
    }
    if (clearConnecting) {
      _connecting = null;
      _connectionEpoch++;
    }
    if (_ack != null && !_ack!.isCompleted) {
      _ack!.completeError(const KitError('room', 'cancelled'));
    }
    final lobbyClosed = lobby?.close();
    final subscriptions = _subscriptions.toList();
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await lobbyClosed;
  }

  void _foregroundChanged() {
    if (!kit._foreground) {
      kit._background('room', _disconnect());
    } else if (_interested && kit.session.token != null) {
      kit._background('room', _connect());
    }
  }

  void _reset() {
    kit._background('room', _disconnect());
    _roster = null;
    _seen.clear();
    _lastState = null;
    _hasState = false;
    _receivedRevision = -1;
  }

  Future<void> _close() async {
    await _disconnect();
    await _invited.close();
    await _joined.close();
    await _left.close();
    await _online.close();
    await _hostChanged.close();
    await _becameHost.close();
    await _state.close();
    await _events.close();
    await _control.close();
    await _rosterChanged.close();
  }
}

final class _Invitation implements KitInvitation {
  _Invitation(this.room, this.roomId, this.from);
  final _Room room;
  @override
  final String roomId;
  @override
  final String from;
  @override
  Future<void> accept() => room._command(
    () => room.id == roomId,
    (lobby) => lobby.party.accept(roomId),
  );
  @override
  Future<void> decline() async {
    await room._connect();
    room._lobby!.party.decline(roomId);
  }
}
