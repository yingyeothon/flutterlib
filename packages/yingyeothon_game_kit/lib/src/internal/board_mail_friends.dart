part of 'game_kit_impl.dart';

final class _Board implements KitBoard {
  _Board(this.kit, this.alias);
  final GameKitImpl kit;
  final String alias;
  LeaderboardInfo? _info;
  Leaderboard get _wire => kit._board(alias);
  @override
  List<String> get periods => List.unmodifiable(
    _info?.periods.map((p) => p.period) ?? const <String>[],
  );
  @override
  String? get rule => _info?.rule;
  @override
  String? get order => _info?.order;
  @override
  Future<void> info() async {
    _info = await kit._run('board', _wire.info);
  }

  @override
  Future<List<KitScore>> submit(int score, {String? meta}) async {
    final generation = kit._generation;
    if (_info == null) await info();
    kit._guard(generation, 'board');
    if (_info!.submit == LbSubmit.server) {
      throw const KitError('board', 'server_only');
    }
    final written = await kit._run(
      'board',
      () => _wire.submit(score, meta: meta),
    );
    final results = <KitScore>[];
    for (final period in written.periods) {
      kit._guard(generation, 'board');
      try {
        final mine = await me(period.bucket.period);
        if (mine != null) results.add(mine);
      } on KitError catch (error) {
        kit._guard(generation, 'board');
        kit._refused.emit(error);
        results.add(
          KitScore(
            userId: kit.session.userId!,
            score: period.score,
            rank: null,
            period: period.bucket.period,
            endsAt: period.bucket.periodEndsAt,
          ),
        );
      }
    }
    return List.unmodifiable(results);
  }

  @override
  Future<List<KitScore>> top(
    String period, {
    int limit = 20,
    int offset = 0,
  }) async {
    final page = await kit._run(
      'board',
      () => _wire.top(period: period, limit: limit, offset: offset),
    );
    return List.unmodifiable(
      page.entries.map(
        (row) => KitScore(
          userId: row.owner,
          score: row.score,
          rank: row.rank,
          period: page.bucket.period,
          meta: row.meta,
          total: page.total,
          endsAt: page.bucket.periodEndsAt,
        ),
      ),
    );
  }

  @override
  Future<KitScore?> me(String period) async {
    final row = await kit._run('board', () => _wire.score(period: period));
    return row == null
        ? null
        : KitScore(
            userId: row.owner,
            score: row.score,
            rank: row.rank,
            period: row.bucket.period,
            meta: row.meta,
            total: row.total,
            endsAt: row.bucket.periodEndsAt,
          );
  }

  @override
  Future<List<KitScore>> around(String period, {int span = 2}) async {
    if (span < 0 || span > 49) {
      throw ArgumentError('board span must be between zero and forty-nine');
    }
    final row = await me(period);
    if (row == null) return const [];
    return top(
      period,
      limit: span * 2 + 1,
      offset: ((row.rank ?? 1) - span - 1).clamp(0, 1000),
    );
  }
}

final class _Mail implements KitMail {
  _Mail(this.kit) {
    _poller = _Poller(
      kit,
      'mail',
      kit._options.mailInterval,
      _poll,
      () => _arrived.hasListener,
    );
  }
  final GameKitImpl kit;
  final Emitter<KitLetter> _arrived = Emitter<KitLetter>();
  final Set<String> _seen = {};
  late final _Poller _poller;
  KvNamespace get _wire => kit._collection('mail').mine;
  @override
  Stream<KitLetter> get arrived {
    _wire;
    scheduleMicrotask(_poller.wake);
    return _arrived.stream;
  }

  KitLetter _letter(String key, KvEntry value) => KitLetter(
    id: key,
    from: value.from,
    at: value.updatedAt,
    value: KitJson.copy(value.value),
    expiresAt: value.expiresAt,
  );
  @override
  Future<List<KitLetter>> list() async {
    final letters = <KitLetter>[];
    String? cursor;
    do {
      final page = await kit._run(
        'mail',
        () => _wire.list(cursor: cursor, values: true),
      );
      for (final row in page.entries) {
        letters.add(
          KitLetter(
            id: row.key,
            from: row.from,
            at: row.updatedAt,
            value: KitJson.copy(row.value),
            expiresAt: row.expiresAt,
          ),
        );
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    letters.sort((a, b) => (b.at ?? 0).compareTo(a.at ?? 0));
    return List.unmodifiable(letters);
  }

  @override
  Future<KitLetter?> read(String id) async {
    final value = await kit._run('mail', () => _wire.getEntry(id));
    return value == null ? null : _letter(id, value);
  }

  @override
  Future<KitLetter> claim(String id) async {
    final value = await kit._run('mail', () => _wire.getEntry(id));
    if (value == null) throw const KitError('mail', 'already_claimed');
    try {
      final deleted = await kit._run(
        'mail',
        () => _wire.deleteIfVersion(id, version: value.version),
      );
      if (!deleted) throw const KitError('mail', 'already_claimed');
    } on KitError catch (e) {
      if (e.code == 'conflict') throw const KitError('mail', 'already_claimed');
      rethrow;
    }
    return _letter(id, value);
  }

  @override
  Future<void> remove(String id) => kit._run('mail', () => _wire.delete(id));
  @override
  Future<void> send(String to, Object? value, {int? ttl}) async {
    final col = kit._collection('mail');
    final info = await kit._run('mail', col.info);
    if (!info.acceptsMail) throw const KitError('mail', 'server_only');
    final key = '${kit.session.userId}:${kit._randomId()}';
    try {
      await kit._run('mail', () => col.owner(to).put(key, value, ttl: ttl));
    } on KitError catch (e) {
      if (e.code == 'conflict') {
        throw const KitError('mail', 'inbox_full', retryable: true);
      }
      rethrow;
    }
  }

  Future<void> _poll() async {
    final letters = await list();
    for (final letter in letters.reversed) {
      if (_seen.add(letter.id)) _arrived.emit(letter);
    }
  }

  void _reset() {
    _seen.clear();
    _poller.stop();
  }

  Future<void> _close() async {
    _poller.stop();
    await _arrived.close();
  }
}

final class _Friends implements KitFriends {
  _Friends(this.kit) {
    _poller = _Poller(
      kit,
      'friends',
      kit._options.mailInterval,
      _poll,
      () => _requested.hasListener,
    );
  }
  final GameKitImpl kit;
  final Emitter<String> _requested = Emitter<String>();
  final Set<String> _seen = {};
  final Map<String, KitFriend> _profiles = {};
  late final _Poller _poller;
  SocialClient get _wire => kit._socialClient();
  @override
  Stream<String> get requested {
    _wire;
    scheduleMicrotask(_poller.wake);
    return _requested.stream;
  }

  @override
  Future<List<KitFriend>> list() async {
    final rows = await kit._run('friends', _wire.friends);
    final online = <String, bool>{};
    for (var n = 0; n < rows.length; n += 50) {
      final presence = await kit._run(
        'friends',
        () => kit._presenceClient().users(
          rows.skip(n).take(50).map((r) => r.owner).toList(),
        ),
      );
      for (final row in presence) {
        online[row.userId] = row.online;
      }
    }
    return List.unmodifiable(
      rows.map(
        (r) => KitFriend(
          userId: r.owner,
          online: online[r.owner] ?? false,
          displayName: r.displayName,
          avatar: r.avatar,
        ),
      ),
    );
  }

  @override
  Future<KitFriendRequests> requests() async {
    final requests = await kit._run('friends', _wire.requests);
    return KitFriendRequests(
      incoming: requests.incoming.map((r) => r.owner).toList(),
      outgoing: requests.outgoing.map((r) => r.owner).toList(),
    );
  }

  @override
  Future<void> request(String userId) async {
    await kit._run('friends', () => _wire.request(userId));
  }

  @override
  Future<void> accept(String userId) =>
      kit._run('friends', () => _wire.accept(userId));
  @override
  Future<void> decline(String userId) =>
      kit._run('friends', () => _wire.decline(userId));
  @override
  Future<void> remove(String userId) =>
      kit._run('friends', () => _wire.unfriend(userId));
  @override
  Future<void> block(String userId) =>
      kit._run('friends', () => _wire.block(userId));
  @override
  Future<void> unblock(String userId) =>
      kit._run('friends', () => _wire.unblock(userId));
  @override
  Future<KitFriend?> myProfile() async {
    final profile = await kit._run('friends', _wire.myProfile);
    return profile == null
        ? null
        : KitFriend(
            userId: profile.owner,
            online: false,
            displayName: profile.displayName,
            avatar: profile.avatar,
          );
  }

  @override
  Future<void> setProfile(String displayName, {String? avatar}) async {
    await kit._run(
      'friends',
      () => _wire.putMyProfile(displayName, avatar: avatar),
    );
    if (kit.session.userId != null) _profiles.remove(kit.session.userId);
  }

  @override
  Future<List<KitFriend>> profiles(List<String> ids) async {
    if (ids.length > 50) {
      throw ArgumentError('profiles accepts at most fifty identities');
    }
    final missing = ids.where((id) => !_profiles.containsKey(id)).toList();
    if (missing.isNotEmpty) {
      final values = await kit._run('friends', () => _wire.profiles(missing));
      for (final value in values) {
        _profiles[value.owner] = KitFriend(
          userId: value.owner,
          online: false,
          displayName: value.displayName,
          avatar: value.avatar,
        );
      }
    }
    return List.unmodifiable(
      ids.map((id) => _profiles[id]).whereType<KitFriend>(),
    );
  }

  @override
  Future<void> invite(String userId) => kit.room.invite(userId);
  Future<void> _poll() async {
    final requests = await this.requests();
    for (final user in requests.incoming) {
      if (_seen.add(user)) _requested.emit(user);
    }
  }

  void _reset() {
    _seen.clear();
    _profiles.clear();
    _poller.stop();
  }

  Future<void> _close() async {
    _poller.stop();
    await _requested.close();
  }
}
