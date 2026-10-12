part of 'game_kit_impl.dart';

const _zeroHash =
    '0000000000000000000000000000000000000000000000000000000000000000';
final _hashWord = RegExp(r'^[a-f0-9]{64}$');

final class _Turns implements KitTurns {
  _Turns(this.kit) {
    _subscription = kit._room._control.stream.listen((event) {
      if (event.name == 'kit.turns.start' &&
          event.from == kit._room.host &&
          event.payload is JsonObject) {
        _announcement = event.payload! as JsonObject;
        _game?._announce(_announcement!);
      } else if (event.name == 'kit.turns.start' &&
          _game?._assembly != null &&
          event.payload is JsonObject &&
          _game!._eligibleResponder(event.from)) {
        _game?._announce(event.payload! as JsonObject);
      } else {
        _game?._receive(event);
      }
    });
  }
  final GameKitImpl kit;
  late final StreamSubscription<KitRoomEvent> _subscription;
  JsonObject? _announcement;
  _TurnGame? _game;
  @override
  Future<KitTurnGame> start({
    required Object? initial,
    required Object? Function(Object?, Object?, String) apply,
    List<String>? players,
    bool persist = false,
    bool resume = true,
    String? saveResultAs,
    String? resultBoard,
    int Function(Object?)? scoreForResult,
  }) async {
    final generation = kit._generation;
    await kit._room._connect();
    kit._guard(generation, 'turns');
    if (kit._room.id == null) throw const KitError('turns', 'invalid_state');
    final order = List<String>.of(
      players ?? kit._room.members.map((m) => m.userId),
    );
    if (order.isEmpty ||
        order.toSet().length != order.length ||
        order.any((u) => !kit._room.members.any((m) => m.userId == u))) {
      throw ArgumentError('turn players must be distinct room members');
    }
    if ((resultBoard == null) != (scoreForResult == null)) {
      throw ArgumentError('result board requires a score conversion');
    }
    await _game?.close();
    final game = _TurnGame(
      this,
      KitJson.copy(initial),
      apply,
      order,
      persist,
      saveResultAs,
      resultBoard,
      scoreForResult,
    );
    _game = game;
    try {
      if (kit._room.isHost) {
        final restored =
            persist && resume && await game._restore(requireAssembly: false);
        if (restored) {
          await game._restoreResult();
          if (!game._ready.isCompleted) game._ready.complete();
        }
        if (restored &&
            !game._finished &&
            kit.room.members.any(
              (m) => m.userId != kit.session.userId && m.online,
            )) {
          await game.resync();
        }
        final announcement = <String, Object?>{
          'gameId': game._gameId ?? kit._randomId(),
          'players': order,
          'initialHash': KitJson.hash(initial),
        };
        game._announce(announcement);
        await game._sendControl('kit.turns.start', announcement);
      } else {
        if (_announcement != null) game._announce(_announcement!);
        await game.resync();
      }
      if (persist && game._log.isEmpty) game._dirty = true;
      if (persist && game._dirty) await game._serial(game._persist);
      await game._restoreResult();
      return game;
    } catch (_) {
      await game.close();
      rethrow;
    } finally {
      if (!game._ready.isCompleted) game._ready.complete();
    }
  }

  void _reset() {
    final game = _game;
    _game = null;
    _announcement = null;
    if (game != null) kit._background('turns', game.close());
  }

  void _connected() {
    if (_game != null) kit._background('turns', _game!._resume());
  }

  void _foregroundChanged() {
    final game = _game;
    if (game != null) kit._background('turns', game._resume());
  }

  Future<void> _close() async {
    await _subscription.cancel();
    await _game?.close();
  }
}

final class _Assembly {
  _Assembly(this.requestId, this.completer);
  final String requestId;
  final Completer<void> completer;
  Timer? timer;
  String? responder;
  JsonObject? manifest;
  final Map<int, List<JsonObject>> parts = {};
  int bytes = 0;
}

final class _TurnGame implements KitTurnGame {
  _TurnGame(
    this.owner,
    this._initial,
    this._apply,
    this._players,
    this._persistEnabled,
    this._saveResultAs,
    this._resultBoard,
    this._scoreForResult,
  ) : _generation = owner.kit._generation,
      _state = KitJson.copy(_initial),
      _lastTick = owner.kit._now;
  final _Turns owner;
  final int _generation;
  GameKitImpl get kit => owner.kit;
  final Object? _initial;
  final Object? Function(Object?, Object?, String) _apply;
  final List<String> _players;
  final bool _persistEnabled;
  final String? _saveResultAs, _resultBoard;
  final int Function(Object?)? _scoreForResult;
  Object? _state;
  String? _gameId;
  final List<JsonObject> _log = [];
  bool _boardSaved = false;
  bool _frozen = false,
      _closed = false,
      _finished = false,
      _resultSaved = false,
      _dirty = false;
  Object? _result;
  final Map<String, int> _elapsed = {};
  int _lastTick;
  final Emitter<KitTurnEvent> _turned = Emitter<KitTurnEvent>();
  final Emitter<KitError> _mismatch = Emitter<KitError>();
  Future<void> _lane = Future.value();
  final Completer<void> _ready = Completer<void>();
  _Assembly? _assembly;
  ({String requestId, String responder, String gameId, int count, String hash})?
  _lastReplay;
  final List<JsonObject> _buffer = [];
  final Map<String, JsonObject> _pendingReplies = {};
  ({JsonObject data, String from})? _pendingFinish;
  final Set<Timer> _replyTimers = {};
  @override
  Object? get state => KitJson.copy(_state);
  @override
  int get index => _log.length;
  @override
  bool get finished => _finished;
  @override
  Object? get result => _finished ? KitJson.copy(_result) : null;
  @override
  bool get frozen => _frozen;
  @override
  Map<String, int> get elapsed {
    final result = Map<String, int>.of(_elapsed);
    if (!_finished && !_frozen && !_closed) {
      final player = _players[index % _players.length];
      result[player] = (result[player] ?? 0) + kit._now - _lastTick;
    }
    return Map.unmodifiable(result);
  }

  @override
  Stream<KitTurnEvent> get turned => _turned.stream;
  @override
  Stream<KitError> get mismatch => _mismatch.stream;
  String get _finalHash =>
      _log.isEmpty ? _zeroHash : _log.last.getString('hash')!;
  void _alive() {
    kit._guard(_generation, 'turns');
    if (_closed) throw const KitError('turns', 'invalid_state');
  }

  Future<void> _sendControl(
    String name,
    Object? payload, {
    String? to,
    bool control = true,
  }) async {
    _alive();
    await kit._room._send(name, payload, to: to, control: control);
    _alive();
  }

  Future<Object?> _saveLoad(String name) async {
    _alive();
    final value = await kit.save.load(name);
    _alive();
    return value;
  }

  Future<void> _saveStore(String name, Object? value, {int? ttl}) async {
    _alive();
    await kit.save.store(name, value, ttl: ttl);
    _alive();
  }

  void _check() {
    _alive();
    if (_closed || _gameId == null) {
      throw const KitError('turns', 'invalid_state');
    }
    if (_frozen) throw const KitError('turns', 'mismatch');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final generation = _generation;
    final task = _lane.then<T>((_) {
      kit._guard(generation, 'turns');
      if (_closed) throw const KitError('turns', 'invalid_state');
      return action();
    });
    _lane = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  void _announce(JsonObject value) {
    if (_closed) return;
    final game = value.getString('gameId');
    final players = value['players'];
    if (game == null ||
        game.isEmpty ||
        players is! List ||
        !players.every((v) => v is String) ||
        Json.encode(players) != Json.encode(_players) ||
        value['initialHash'] != KitJson.hash(_initial)) {
      _freeze();
      return;
    }
    if (_gameId != null && _gameId != game) return;
    _gameId = game;
  }

  void _freeze() {
    if (_frozen || _closed) return;
    _frozen = true;
    final error = const KitError('turns', 'mismatch');
    _mismatch.emit(error);
    final assembly = _assembly;
    _assembly = null;
    assembly?.timer?.cancel();
    if (assembly != null && !assembly.completer.isCompleted) {
      assembly.completer.completeError(error);
    }
  }

  bool _recordShape(JsonObject record) =>
      record.getInt('index') != null &&
      record.getInt('index')! >= 0 &&
      record.getString('by') != null &&
      record.has('move') &&
      record.getString('hash') != null &&
      _hashWord.hasMatch(record.getString('hash')!);
  Object? _reduce(
    Object? before,
    JsonObject record,
    int index,
    String previous,
  ) {
    if (!_recordShape(record) ||
        record['index'] != index ||
        record['by'] != _players[index % _players.length] ||
        record['hash'] !=
            KitJson.hash([previous, index, record['by'], record['move']])) {
      throw const KitError('turns', 'mismatch');
    }
    return KitJson.copy(
      _apply(
        KitJson.copy(before),
        KitJson.copy(record['move']),
        record.getString('by')!,
      ),
    );
  }

  void _accept(JsonObject record, String from) {
    if (_closed || _frozen || record['gameId'] != _gameId) return;
    if (record['by'] != from ||
        !_recordShape(record) ||
        KitJson.bytes(record) > 7000) {
      _freeze();
      return;
    }
    final n = record.getInt('index')!;
    if (n < index) {
      if (KitJson.canonical(record) != KitJson.canonical(_log[n])) _freeze();
      return;
    }
    if (_finished || n != index) {
      _freeze();
      return;
    }
    try {
      final next = _reduce(_state, record, n, _finalHash);
      _elapsed[from] = (_elapsed[from] ?? 0) + kit._now - _lastTick;
      _lastTick = kit._now;
      _state = next;
      _log.add(KitJson.copy(record)! as JsonObject);
      _dirty = true;
      _turned.emit(
        KitTurnEvent(
          state: state,
          move: KitJson.copy(record['move']),
          by: from,
          index: n,
        ),
      );
    } catch (_) {
      _freeze();
    }
  }

  @override
  Future<void> submit(Object? move) => _serial(() async {
    _check();
    if (_finished || _assembly != null) {
      throw const KitError('turns', 'invalid_state');
    }
    final by = kit.session.userId!;
    if (_players[index % _players.length] != by) {
      throw const KitError('turns', 'not_your_turn');
    }
    final copied = KitJson.copy(move);
    final record = <String, Object?>{
      'gameId': _gameId,
      'index': index,
      'move': copied,
      'by': by,
      'hash': KitJson.hash([_finalHash, index, by, copied]),
    };
    if (KitJson.bytes(record) > 7000) {
      throw const KitError('turns', 'payload_too_large');
    }
    // Reject an invalid local move before any event crosses the transport.
    try {
      _reduce(_state, record, index, _finalHash);
    } catch (_) {
      throw const KitError('turns', 'invalid_state');
    }
    await _sendControl('kit.turn', record, control: true);
    _accept(record, by);
    if (_frozen) throw const KitError('turns', 'mismatch');
    if (_persistEnabled) await _persist();
  });
  void _receive(KitRoomEvent event) {
    if (_closed || event.payload is! JsonObject) return;
    final data = event.payload! as JsonObject;
    if (event.name == 'kit.turns.log') {
      _reply(event.from, data);
      return;
    }
    if (_gameId != null && data['gameId'] != _gameId) return;
    switch (event.name) {
      case 'kit.turn':
        if (_assembly != null) {
          if (data['by'] != event.from ||
              !_recordShape(data) ||
              KitJson.bytes(data) > 7000 ||
              _buffer.fold(0, (n, r) => n + KitJson.bytes(r)) +
                      KitJson.bytes(data) >
                  kit._options.maxLogBytes) {
            _freeze();
            return;
          }
          _buffer.add(KitJson.copy(data)! as JsonObject);
        } else {
          final before = index;
          _accept(data, event.from);
          if (index > before && _persistEnabled) {
            kit._background('turns', _serial(_persist));
          }
        }
      case 'kit.turns.manifest':
        _manifest(event.from, data);
      case 'kit.turns.chunk':
        _chunk(event.from, data);
      case 'kit.turns.finish':
        final replay = _lastReplay;
        final assembling = _assembly;
        final duringAssembly =
            assembling?.responder == event.from &&
            data['requestId'] == assembling?.requestId &&
            assembling?.manifest != null &&
            data['count'] == assembling!.manifest!['count'] &&
            data['finalHash'] == assembling.manifest!['finalHash'];
        final delegated =
            replay != null &&
            replay.responder == event.from &&
            data['requestId'] == replay.requestId &&
            data['gameId'] == replay.gameId &&
            data['count'] == replay.count &&
            data['finalHash'] == replay.hash;
        if (event.from != kit._room.host && !delegated && !duringAssembly) {
          return;
        }
        if (_assembly != null) {
          _pendingFinish = (data: data, from: event.from);
        } else {
          kit._background('turns', _serial(() => _finishMarker(data)));
        }
    }
  }

  List<List<JsonObject>> _pack(int cap, {required int overhead}) {
    final parts = <List<JsonObject>>[];
    var current = <JsonObject>[];
    for (final record in _log) {
      if (utf8.encode(Json.encode([...current, record])).length + overhead >
          cap) {
        if (current.isEmpty) throw const KitError('turns', 'payload_too_large');
        parts.add(current);
        current = [];
      }
      current.add(record);
    }
    if (current.isNotEmpty) parts.add(current);
    return parts;
  }

  void _reply(String to, JsonObject request) {
    if (_gameId == null ||
        _closed ||
        _frozen ||
        to == kit.session.userId ||
        request.getString('requestId') == null ||
        (request['gameId'] != '' && request['gameId'] != _gameId)) {
      return;
    }
    final currentHost = kit._room.host;
    final others = _players
        .where(
          (u) =>
              u != to &&
              u != currentHost &&
              kit._room.members.any((m) => m.userId == u && m.online),
        )
        .toList();
    final local = kit.session.userId;
    final host = local == currentHost;
    if (host && _assembly != null) {
      _pendingReplies[to] = KitJson.copy(request)! as JsonObject;
      return;
    }
    if (!host &&
        (others.isEmpty ||
            others.first != local ||
            (_assembly != null && _log.isEmpty))) {
      return;
    }
    late final Timer timer;
    timer = Timer(host ? Duration.zero : const Duration(milliseconds: 200), () {
      _replyTimers.remove(timer);
      if (_closed || _frozen || !kit._foreground) return;
      kit._background('turns', _sendLog(to, request.getString('requestId')!));
    });
    _replyTimers.add(timer);
  }

  Future<void> _sendLog(String to, String requestId) async {
    await _ready.future;
    _alive();
    final gameId = _gameId;
    final records = _pack(8192, overhead: 1000)
        .map((p) => p.map((r) => KitJson.copy(r)! as JsonObject).toList())
        .toList();
    final count = index, hash = _finalHash;
    final finished = _finished;
    final result = finished ? KitJson.copy(_result) : null;
    await _sendControl(
      'kit.turns.start',
      {
        'gameId': gameId,
        'players': _players,
        'initialHash': KitJson.hash(_initial),
      },
      to: to,
      control: true,
    );
    await _sendControl(
      'kit.turns.manifest',
      {
        'gameId': gameId,
        'requestId': requestId,
        'count': count,
        'finalHash': hash,
        'chunks': records.length,
      },
      to: to,
      control: true,
    );
    for (var part = 0; part < records.length; part++) {
      if (_closed || !kit._foreground) {
        throw const KitError('turns', 'cancelled');
      }
      if (part > 0) await _pause(const Duration(milliseconds: 200));
      await _sendControl(
        'kit.turns.chunk',
        {
          'gameId': gameId,
          'requestId': requestId,
          'part': part,
          'records': records[part],
        },
        to: to,
        control: true,
      );
    }
    if (finished) {
      await _sendControl(
        'kit.turns.finish',
        {
          'gameId': gameId,
          'requestId': requestId,
          'result': result,
          'count': count,
          'finalHash': hash,
        },
        to: to,
        control: true,
      );
    }
  }

  Future<void> _pause(Duration duration) {
    final completer = Completer<void>();
    late final Timer timer;
    timer = Timer(duration, () {
      _replyTimers.remove(timer);
      completer.complete();
    });
    _replyTimers.add(timer);
    _waiting[timer] = completer;
    return completer.future.whenComplete(() => _waiting.remove(timer));
  }

  final Map<Timer, Completer<void>> _waiting = {};
  bool _eligibleResponder(String from) {
    final host = kit._room.host, local = kit.session.userId;
    if (from == local ||
        !kit._room.members.any((m) => m.userId == from && m.online)) {
      return false;
    }
    if (from == host) return true;
    final fallback = _players
        .where(
          (u) =>
              u != local &&
              u != host &&
              kit._room.members.any((m) => m.userId == u && m.online),
        )
        .firstOrNull;
    return from == fallback;
  }

  void _manifest(String from, JsonObject data) {
    final assembly = _assembly;
    if (!_eligibleResponder(from)) return;
    if (assembly == null ||
        data['requestId'] != assembly.requestId ||
        _gameId == null ||
        data['gameId'] != _gameId) {
      return;
    }
    if (assembly.responder != null && assembly.responder != from) return;
    final count = data.getInt('count'), chunks = data.getInt('chunks');
    final hash = data.getString('finalHash');
    if (count == null ||
        count < index ||
        count > kit._options.maxLogBytes ||
        chunks == null ||
        chunks < 0 ||
        chunks > count ||
        hash == null ||
        !_hashWord.hasMatch(hash) ||
        (count == 0) != (chunks == 0)) {
      _freeze();
      return;
    }
    if (assembly.manifest != null &&
        KitJson.canonical(assembly.manifest) != KitJson.canonical(data)) {
      _freeze();
      return;
    }
    assembly.responder = from;
    assembly.manifest = data;
    _commitAssembly();
  }

  void _chunk(String from, JsonObject data) {
    final assembly = _assembly;
    if (assembly == null ||
        assembly.responder != from ||
        data['requestId'] != assembly.requestId ||
        assembly.manifest == null) {
      return;
    }
    final part = data.getInt('part'), raw = data['records'];
    if (part == null ||
        part < 0 ||
        part >= assembly.manifest!.getInt('chunks')! ||
        raw is! List ||
        raw.any((r) => r is! JsonObject)) {
      _freeze();
      return;
    }
    final records = raw
        .cast<JsonObject>()
        .map((r) => KitJson.copy(r)! as JsonObject)
        .toList();
    if (assembly.parts.containsKey(part)) {
      if (KitJson.canonical(assembly.parts[part]) !=
          KitJson.canonical(records)) {
        _freeze();
      }
      return;
    }
    final bytes = KitJson.bytes(records);
    if (bytes > 8192 || assembly.bytes + bytes > kit._options.maxLogBytes) {
      _freeze();
      return;
    }
    assembly.bytes += bytes;
    assembly.parts[part] = records;
    _commitAssembly();
  }

  void _commitAssembly() {
    final assembly = _assembly;
    final manifest = assembly?.manifest;
    if (assembly == null ||
        manifest == null ||
        assembly.parts.length != manifest['chunks']) {
      return;
    }
    final records = <JsonObject>[
      for (var n = 0; n < assembly.parts.length; n++) ...assembly.parts[n]!,
    ];
    try {
      var state = KitJson.copy(_initial), hash = _zeroHash;
      if (records.length != manifest['count']) {
        throw const KitError('turns', 'mismatch');
      }
      for (var n = 0; n < records.length; n++) {
        final record = records[n];
        if (record['gameId'] != _gameId || KitJson.bytes(record) > 7000) {
          throw const KitError('turns', 'mismatch');
        }
        if (n < index &&
            KitJson.canonical(record) != KitJson.canonical(_log[n])) {
          throw const KitError('turns', 'mismatch');
        }
        state = _reduce(state, record, n, hash);
        hash = record.getString('hash')!;
      }
      if (hash != manifest['finalHash']) {
        throw const KitError('turns', 'mismatch');
      }
      _lastReplay = (
        requestId: assembly.requestId,
        responder: assembly.responder!,
        gameId: _gameId!,
        count: records.length,
        hash: hash,
      );
      _log
        ..clear()
        ..addAll(records);
      _state = state;
      _assembly = null;
      assembly.timer?.cancel();
      _lastTick = kit._now;
      _dirty = true;
      _drainRecovered();
      if (!assembly.completer.isCompleted) assembly.completer.complete();
    } catch (_) {
      _assembly = assembly;
      _freeze();
    }
  }

  void _drainRecovered() {
    final buffered = _buffer.toList()
      ..sort((a, b) => a.getInt('index')!.compareTo(b.getInt('index')!));
    _buffer.clear();
    for (final record in buffered) {
      _accept(record, record.getString('by')!);
    }
    if (_frozen) throw const KitError('turns', 'mismatch');
    final replies = Map<String, JsonObject>.of(_pendingReplies);
    _pendingReplies.clear();
    for (final reply in replies.entries) {
      _reply(reply.key, reply.value);
    }
    final finish = _pendingFinish;
    _pendingFinish = null;
    if (finish != null) {
      _validateFinish(finish.data);
      kit._background('turns', _serial(_saveResult));
    }
  }

  @override
  Future<void> resync() async {
    _alive();
    if (_closed || _frozen) throw const KitError('turns', 'invalid_state');
    if (_assembly != null) return _assembly!.completer.future;
    await kit._room._connect();
    if (_assembly != null) return _assembly!.completer.future;
    final assembly = _Assembly(kit._randomId(), Completer<void>());
    _assembly = assembly;
    _buffer.clear();
    assembly.timer = Timer(const Duration(seconds: 30), () {
      if (!identical(_assembly, assembly)) return;
      _assembly = null;
      _pendingFinish = null;
      _buffer.clear();
      if (!assembly.completer.isCompleted) {
        assembly.completer.completeError(
          const KitError('turns', 'unavailable', retryable: true),
        );
      }
    });
    // Attach the completion handler before emitting: a fake may reply synchronously.
    final outcome = assembly.completer.future;
    unawaited(outcome.then<void>((_) {}, onError: (Object _) {}));
    try {
      final restored = _persistEnabled && await _restore();
      if (restored) {
        await _restoreResult();
        if (!_ready.isCompleted) _ready.complete();
      }
      if (restored &&
          !kit._room.members.any(
            (m) => m.userId != kit.session.userId && m.online,
          )) {
        if (identical(_assembly, assembly)) {
          _assembly = null;
          assembly.timer?.cancel();
          try {
            _drainRecovered();
            assembly.completer.complete();
          } catch (_) {
            _assembly = assembly;
            _freeze();
          }
        }
      } else {
        await _sendControl('kit.turns.log', {
          'gameId': _gameId ?? '',
          'requestId': assembly.requestId,
        }, control: true);
      }
      await outcome;
    } catch (error) {
      if (identical(_assembly, assembly)) {
        _assembly = null;
        assembly.timer?.cancel();
      }
      if (error is KitError && error.code == 'mismatch') _freeze();
      rethrow;
    }
  }

  Future<void> _persist() async {
    if (!_persistEnabled || !_dirty || _gameId == null) return;
    final manifestKey = 'turns:${kit._room.id}';
    final gameId = _gameId!, count = index, hash = _finalHash;
    final chunks = _pack(16384, overhead: 0)
        .map((part) => part.map((r) => KitJson.copy(r)! as JsonObject).toList())
        .toList();
    await _saveLoad(manifestKey);
    final revision = kit._randomId();
    for (var n = 0; n < chunks.length; n++) {
      await _saveStore(
        '$manifestKey:$gameId:$revision:$n',
        chunks[n],
        ttl: kit._options.logTtlSeconds,
      );
    }
    await _saveStore(manifestKey, {
      'v': 1,
      'gameId': gameId,
      'players': _players,
      'initialHash': KitJson.hash(_initial),
      'revision': revision,
      'chunks': chunks.length,
      'count': count,
      'finalHash': hash,
    }, ttl: kit._options.logTtlSeconds);
    _dirty = index != count || _finalHash != hash;
  }

  Future<bool> _restore({bool requireAssembly = true}) async {
    final key = 'turns:${kit._room.id}';
    final value = await _saveLoad(key);
    if (value is! JsonObject ||
        value['v'] != 1 ||
        value['initialHash'] != KitJson.hash(_initial) ||
        Json.encode(value['players']) != Json.encode(_players) ||
        value.getString('gameId') == null ||
        (_gameId != null && value['gameId'] != _gameId)) {
      return false;
    }
    final chunks = value.getInt('chunks'),
        count = value.getInt('count'),
        revision = value.getString('revision');
    if (chunks == null ||
        chunks < 0 ||
        chunks > kit._options.maxLogBytes ||
        count == null ||
        count < 0 ||
        revision == null) {
      throw const KitError('turns', 'mismatch');
    }
    final records = <JsonObject>[];
    var bytes = 0;
    for (var n = 0; n < chunks; n++) {
      if ((requireAssembly && _assembly == null) || _closed) {
        throw const KitError('turns', 'unavailable', retryable: true);
      }
      final part = await _saveLoad('$key:${value['gameId']}:$revision:$n');
      if (part is! List || part.any((r) => r is! JsonObject)) return false;
      bytes += KitJson.bytes(part);
      if (bytes > kit._options.maxLogBytes) {
        throw const KitError('turns', 'mismatch');
      }
      records.addAll(part.cast<JsonObject>());
    }
    var state = KitJson.copy(_initial), hash = _zeroHash;
    if (records.length != count) {
      throw const KitError('turns', 'mismatch');
    }
    for (var n = 0; n < records.length; n++) {
      if (records[n]['gameId'] != value['gameId'] ||
          KitJson.bytes(records[n]) > 7000) {
        throw const KitError('turns', 'mismatch');
      }
      if (n < index &&
          KitJson.canonical(records[n]) != KitJson.canonical(_log[n])) {
        throw const KitError('turns', 'mismatch');
      }
      state = _reduce(state, records[n], n, hash);
      hash = records[n].getString('hash')!;
    }
    if (hash != value['finalHash']) throw const KitError('turns', 'mismatch');
    if (count < index) return false;
    _gameId = value.getString('gameId');
    _state = state;
    _log
      ..clear()
      ..addAll(records);
    _dirty = false;
    return true;
  }

  void _validateFinish(JsonObject data) {
    if (data['gameId'] != _gameId || !data.has('result')) return;
    if (data['count'] != index || data['finalHash'] != _finalHash) {
      _freeze();
      throw const KitError('turns', 'mismatch');
    }
    if (_finished &&
        KitJson.canonical(data['result']) != KitJson.canonical(_result)) {
      _freeze();
      throw const KitError('turns', 'mismatch');
    }
    _finished = true;
    _result = KitJson.copy(data['result']);
  }

  Future<void> _finishMarker(JsonObject data) async {
    _validateFinish(data);
    if (_finished && !_frozen) await _saveResult();
  }

  Future<void> _restoreResult() async {
    if (_saveResultAs != null && _gameId != null) {
      final saved = await _saveLoad(_saveResultAs);
      if (saved is JsonObject &&
          saved['gameId'] == _gameId &&
          saved['finalHash'] == _finalHash &&
          Json.encode(saved['players']) == Json.encode(_players) &&
          saved.has('result')) {
        _finished = true;
        _result = KitJson.copy(saved['result']);
        final boardRef = _resultBoard == null
            ? null
            : kit._section('boards').getString(_resultBoard);
        final acknowledged = boardRef == null || saved['board'] == boardRef;
        _boardSaved = _boardSaved || acknowledged;
        _resultSaved = acknowledged;
      }
    }
  }

  Future<void> _saveResult() async {
    if (_resultSaved) return;
    await _restoreResult();
    if (_resultSaved) return;
    if (_dirty && _persistEnabled) await _persist();
    if (_resultBoard != null && !_boardSaved) {
      _alive();
      await kit.board(_resultBoard).submit(_scoreForResult!(_result));
      _alive();
      _boardSaved = true;
    }
    if (_saveResultAs != null) {
      await _saveStore(_saveResultAs, {
        'gameId': _gameId,
        'result': _result,
        'players': _players,
        'finalHash': _finalHash,
        if (_resultBoard != null)
          'board': kit._section('boards').getString(_resultBoard),
      });
    }
    _resultSaved = true;
  }

  @override
  Future<void> finish(Object? result) => _serial(() async {
    _check();
    if (!kit._room.isHost) throw const KitError('turns', 'invalid_state');
    if (_assembly != null) {
      await _assembly!.completer.future;
    }
    if (_finished && KitJson.canonical(result) != KitJson.canonical(_result)) {
      throw const KitError('turns', 'invalid_state');
    }
    if (!_finished) {
      await _sendControl('kit.turns.finish', {
        'gameId': _gameId,
        'result': KitJson.copy(result),
        'count': index,
        'finalHash': _finalHash,
      }, control: true);
    }
    _finished = true;
    _result = KitJson.copy(result);
    await _saveResult();
  });
  Future<void> _resume() async {
    if (_closed || _frozen) return;
    if (!_finished || _assembly != null) await resync();
    if (_dirty && _persistEnabled) await _serial(_persist);
    if (_finished && !_resultSaved) await _serial(_saveResult);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.complete();
    final assembly = _assembly;
    _assembly = null;
    assembly?.timer?.cancel();
    if (assembly != null && !assembly.completer.isCompleted) {
      assembly.completer.completeError(const KitError('turns', 'cancelled'));
    }
    for (final timer in _replyTimers) {
      timer.cancel();
    }
    _replyTimers.clear();
    for (final completer in _waiting.values) {
      if (!completer.isCompleted) {
        completer.completeError(const KitError('turns', 'cancelled'));
      }
    }
    _waiting.clear();
    await _turned.close();
    await _mismatch.close();
  }
}
