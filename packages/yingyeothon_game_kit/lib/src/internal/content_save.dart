part of 'game_kit_impl.dart';

final class _Content implements KitContent {
  _Content(this.kit) {
    _poller = _Poller(
      kit,
      'content',
      kit._options.contentInterval,
      _poll,
      () => _watchers.values.any((e) => e.hasListener),
    );
  }
  final GameKitImpl kit;
  final Map<String, KvEntry?> _cache = {};
  final Map<String, Emitter<Object?>> _watchers = {};
  late final _Poller _poller;
  final Map<String, Future<Object?>> _pending = {};
  Future<Object?> _read(String key) {
    if (_pending.containsKey(key)) return _pending[key]!;
    final generation = kit._generation;
    final task = kit
        ._run('content', () => kit._collection('content').getEntry(key))
        .then<Object?>((entry) {
          kit._guard(generation, 'content');
          final changed =
              !_cache.containsKey(key) ||
              _cache[key]?.version != entry?.version;
          _cache[key] = entry;
          if (changed) _watchers[key]?.emit(KitJson.copy(entry?.value));
          return KitJson.copy(entry?.value);
        });
    _pending[key] = task;
    unawaited(
      task.then<void>(
        (_) {
          if (identical(_pending[key], task)) _pending.remove(key);
        },
        onError: (Object _) {
          if (identical(_pending[key], task)) _pending.remove(key);
        },
      ),
    );
    return task;
  }

  @override
  Future<Object?> get(String key) async {
    kit._collection('content');
    if (_cache.containsKey(key)) {
      if (kit._foreground) {
        kit._background('content', _read(key).then<void>((_) {}));
      }
      return KitJson.copy(_cache[key]?.value);
    }
    return _read(key);
  }

  @override
  Future<Map<String, Object?>> list({String? prefix}) async {
    final result = <String, Object?>{};
    String? cursor;
    do {
      final page = await kit._run(
        'content',
        () => kit
            ._collection('content')
            .list(prefix: prefix, cursor: cursor, values: true),
      );
      for (final entry in page.entries) {
        result[entry.key] = KitJson.copy(entry.value);
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    return Map.unmodifiable(result);
  }

  @override
  Stream<Object?> subscribe(String key) {
    kit._collection('content');
    final emitter = _watchers.putIfAbsent(key, () => Emitter<Object?>());
    // Delay one microtask so the caller can attach its listener first.
    scheduleMicrotask(_poller.wake);
    return emitter.stream;
  }

  Future<void> _poll() async {
    for (final key in _watchers.keys.toList()) {
      if (_watchers[key]!.hasListener) await _read(key);
    }
  }

  void _reset() {
    _cache.clear();
    _pending.clear();
    _poller.stop();
  }

  Future<void> _close() async {
    _poller.stop();
    for (final e in _watchers.values) {
      await e.close();
    }
  }
}

final class _Save implements KitSave {
  _Save(this.kit);
  final GameKitImpl kit;
  final Map<String, ({Object? value, int? version})> _cache = {};
  List<KitQueuedWrite> _queue = [];
  String? _namespace;
  final Map<String, KitMerge> _inline = {};
  Future<void> _lane = Future.value();
  @override
  int get pendingCount => _queue.length;
  KvNamespace get _wire => kit._collection('save').mine;
  Future<T> _serial<T>(Future<T> Function(int) action) {
    final generation = kit._generation;
    final task = _lane.then<T>((_) {
      kit._guard(generation, 'save');
      return action(generation);
    });
    _lane = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  String _identityKey() => Json.encode([
    kit._section('auth').getString('channelId') ?? '',
    kit._section('state').getString('url'),
    kit._section('collections').getString('save'),
    kit.session.userId,
  ]);
  KitQueuedWrite _copy(KitQueuedWrite write) => KitQueuedWrite(
    id: write.id,
    name: write.name,
    kind: write.kind,
    value: KitJson.copy(write.value),
    expectedVersion: write.expectedVersion,
    ttl: write.ttl,
  );
  Future<void> _hydrate(int generation) async {
    _wire;
    final adapter = kit._options.queueStorage;
    if (adapter == null) return;
    final namespace = _identityKey();
    if (_namespace == namespace) return;
    List<KitQueuedWrite> loaded;
    try {
      loaded = await adapter.load(namespace);
    } catch (_) {
      throw const KitError('save', 'unavailable', retryable: true);
    }
    kit._guard(generation, 'save');
    if (loaded.any(
      (w) =>
          !['store', 'remove'].contains(w.kind) ||
          w.id.isEmpty ||
          w.name.isEmpty ||
          (w.expectedVersion != null && w.expectedVersion! < 1),
    )) {
      throw const KitError('save', 'invalid_state');
    }
    _queue = loaded.map(_copy).toList();
    _namespace = namespace;
  }

  Future<void> _persist(List<KitQueuedWrite> next, int generation) async {
    try {
      await kit._options.queueStorage!.store(
        _namespace!,
        next.map(_copy).toList(),
      );
    } catch (_) {
      throw const KitError('save', 'unavailable', retryable: true);
    }
    kit._guard(generation, 'save');
    _queue = next.map(_copy).toList();
  }

  Future<Object?> _load(String name, int generation) async {
    await _hydrate(generation);
    final staged = _queue.where((w) => w.name == name).lastOrNull;
    if (staged != null) {
      return staged.kind == 'remove' ? null : KitJson.copy(staged.value);
    }
    try {
      final entry = await kit._run('save', () => _wire.getEntry(name));
      kit._guard(generation, 'save');
      _cache[name] = (
        value: KitJson.copy(entry?.value),
        version: entry?.version,
      );
      return KitJson.copy(entry?.value);
    } on KitError catch (e) {
      if (e.code == 'unavailable' &&
          kit._options.queueStorage != null &&
          _cache.containsKey(name)) {
        return KitJson.copy(_cache[name]!.value);
      }
      rethrow;
    }
  }

  @override
  Future<Object?> load(String name) =>
      _serial((generation) => _load(name, generation));
  Future<void> _write(
    String name,
    Object? value,
    KitMerge? merge,
    int? ttl,
    int generation,
  ) async {
    KvRules.checkKey(name);
    KvRules.checkTtl(ttl);
    final copy = KitJson.copy(value);
    if (utf8.encode(Json.encode(copy)).length > 16384) {
      throw ArgumentError('save JSON exceeds 16384 bytes');
    }
    await _hydrate(generation);
    if (!_cache.containsKey(name)) {
      try {
        await _load(name, generation);
      } on KitError catch (e) {
        if (e.code != 'unavailable' || kit._options.queueStorage == null) {
          rethrow;
        }
      }
    }
    final staged = _queue.where((w) => w.name == name).lastOrNull;
    final version = staged?.expectedVersion ?? _cache[name]?.version;
    final write = KitQueuedWrite(
      id: kit._randomId(),
      name: name,
      kind: 'store',
      value: copy,
      expectedVersion: version,
      ttl: ttl,
    );
    if (kit._options.queueStorage != null) {
      await _persist([..._queue, write], generation);
      if (merge != null) _inline[write.id] = merge;
      try {
        await _flush(generation);
      } on KitError catch (e) {
        if (e.code != 'unavailable') rethrow;
      }
    } else {
      await _apply(write, merge, generation, recover: false);
    }
  }

  @override
  Future<void> store(String name, Object? value, {KitMerge? merge, int? ttl}) =>
      _serial((generation) => _write(name, value, merge, ttl, generation));
  @override
  Future<void> update(
    String name,
    Object? Function(Object?) transform, {
    KitMerge? merge,
  }) => _serial((generation) async {
    final value = await _load(name, generation);
    await _write(name, transform(value), merge, null, generation);
  });
  @override
  Future<void> remove(String name) => _serial((generation) async {
    await _hydrate(generation);
    if (!_cache.containsKey(name)) await _load(name, generation);
    final version = _cache[name]?.version;
    if (version == null && !_queue.any((w) => w.name == name)) return;
    final write = KitQueuedWrite(
      id: kit._randomId(),
      name: name,
      kind: 'remove',
      expectedVersion: version,
    );
    if (kit._options.queueStorage != null) {
      await _persist([..._queue, write], generation);
      try {
        await _flush(generation);
      } on KitError catch (e) {
        if (e.code != 'unavailable') rethrow;
      }
    } else {
      await _apply(write, null, generation, recover: false);
    }
  });
  Future<void> _apply(
    KitQueuedWrite original,
    KitMerge? merge,
    int generation, {
    required bool recover,
  }) async {
    var write = original;
    if (recover) {
      final remote = await kit._run('save', () => _wire.getEntry(write.name));
      kit._guard(generation, 'save');
      if (write.kind == 'remove' && remote == null) {
        _cache[write.name] = (value: null, version: null);
        return;
      }
      if (write.kind == 'store' &&
          remote != null &&
          remote.version > (write.expectedVersion ?? 0) &&
          KitJson.canonical(remote.value) == KitJson.canonical(write.value)) {
        _cache[write.name] = (
          value: KitJson.copy(remote.value),
          version: remote.version,
        );
        return;
      }
    }
    for (var retry = 0; ; retry++) {
      try {
        if (write.kind == 'remove') {
          if (write.expectedVersion == null) {
            throw const KitError('save', 'conflict', retryable: true);
          }
          await kit._run(
            'save',
            () => _wire.delete(write.name, ifMatch: write.expectedVersion),
          );
          _cache[write.name] = (value: null, version: null);
        } else {
          final result = await kit._run(
            'save',
            () => _wire.put(
              write.name,
              write.value,
              ifMatch: write.expectedVersion,
              ifNoneMatch: write.expectedVersion == null,
              ttl: write.ttl,
            ),
          );
          _cache[write.name] = (
            value: KitJson.copy(write.value),
            version: result.version,
          );
        }
        return;
      } on KitError catch (e) {
        if (e.code != 'conflict' ||
            write.kind == 'remove' ||
            merge == null ||
            retry >= kit._options.maxMergeRetries) {
          rethrow;
        }
        final remote = await kit._run('save', () => _wire.getEntry(write.name));
        kit._guard(generation, 'save');
        write = KitQueuedWrite(
          id: write.id,
          name: write.name,
          kind: 'store',
          value: KitJson.copy(
            merge(KitJson.copy(write.value), KitJson.copy(remote?.value)),
          ),
          expectedVersion: remote?.version,
          ttl: write.ttl,
        );
        if (kit._options.queueStorage != null) {
          await _persist(
            _queue.map((w) => w.id == write.id ? write : w).toList(),
            generation,
          );
        }
      }
    }
  }

  Future<void> _flush(int generation) async {
    await _hydrate(generation);
    while (_queue.isNotEmpty) {
      final write = _queue.first;
      await _apply(
        write,
        _inline[write.id] ?? kit._mergePolicies[write.name],
        generation,
        recover: true,
      );
      final version = _cache[write.name]?.version;
      final next = _queue
          .skip(1)
          .map(
            (w) => w.name == write.name
                ? KitQueuedWrite(
                    id: w.id,
                    name: w.name,
                    kind: w.kind,
                    value: w.value,
                    expectedVersion: version,
                    ttl: w.ttl,
                  )
                : w,
          )
          .toList();
      await _persist(next, generation);
      _inline.remove(write.id);
    }
  }

  @override
  Future<void> flush() => _serial(_flush);
  @override
  KitCounter counter(String name) => _Counter(this, name);
  @override
  Future<bool> claimOnce(String name, int ttl) => _serial((generation) async {
    try {
      await kit._run(
        'save',
        () => _wire.put(name, true, ifNoneMatch: true, ttl: ttl),
      );
      return true;
    } on KitError catch (e) {
      if (e.code == 'conflict') return false;
      rethrow;
    }
  });
  void _reset() {
    _cache.clear();
    _queue = [];
    _namespace = null;
    _inline.clear();
  }
}

final class _Counter implements KitCounter {
  _Counter(this.save, this.name);
  final _Save save;
  final String name;
  @override
  Future<int> add(int delta, {int? min, int? max}) async =>
      (await save.kit._run(
        'save',
        () => save._wire.incr(name, delta, min: min, max: max),
      )).value;
}
