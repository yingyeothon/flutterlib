import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yingyeothon_kvstore_client/yingyeothon_kvstore_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'config.dart';
import 'map_layout.dart';

/// One line the UI shows: SDK log lines and app notes share the panel.
class LogLine {
  const LogLine(this.text, this.at);
  final String text;
  final DateTime at;
}

/// Where the app has you in the lobby.
class PlayerPosition {
  const PlayerPosition(this.zone, this.x, this.y, this.dir);
  final String zone;
  final double x;
  final double y;
  final String? dir;
}

/// Owns the config, the token, the clients and the log. Screens read it; the
/// debug hooks poke it.
class Session extends ChangeNotifier {
  Session({PlaygroundConfig? config})
    : config = config ?? PlaygroundConfig.fromEnvironment {
    logger = createFilteredLogger(
      severity: LogSeverity.debug,
      writer: LogWriters.fromFunction(
        (s, m, c) => note(LogWriters.format(s, m, c)),
      ),
    );
  }

  PlaygroundConfig config;
  late final Logger logger;

  /// The channel JWT. Held in memory only; never logged, never persisted.
  ChannelToken? token;

  GatewayLobbyClient? lobby;

  /// The lobby's map asset as this app reads it; [MapLayout.fallback] until
  /// `lobby.map()` answers.
  MapLayout mapLayout = MapLayout.fallback;

  /// The position the app last sent, settled after each `hello` by the
  /// gateway's own word. It outlives a reconnect and a new lobby client on
  /// purpose: the gateway retains your position for 30 minutes and checks a
  /// same-zone `pos` against it (`maxMoveDelta`), so resuming from a fixed
  /// spawn point is refused as `move_too_far`. It belongs to one user (the
  /// `hello`'s) on one channel of one gateway, and is dropped when any of
  /// the three changes.
  PlayerPosition? position;
  (String, String, String)? _positionOwner;

  _Placement? _placement;

  /// Between a `hello` and the gateway's answer to the resume `pos`; moves
  /// are held until then, so every own entry that arrives is about that one
  /// `pos` and nothing else is in flight.
  bool get placing => _placement != null;

  /// How long a placement waits for its answer. The clock starts at `hello`
  /// and covers the gateway's own restore round trips, the resume `pos` and a
  /// flush; past it, the batch that would settle it was dropped (a refusal
  /// never is). See [_placementTimedOut].
  static const Duration placementTimeout = Duration(seconds: 5);

  /// Where a player the gateway has no position for starts.
  static const double spawnX = 5;
  static const double spawnY = 5;
  GatewayGameClient? game;
  final List<LogLine> log = <LogLine>[];
  final List<SayBroadcastFrame> chat = <SayBroadcastFrame>[];
  final List<EventBroadcastFrame> events = <EventBroadcastFrame>[];
  final List<Object?> gameFrames = <Object?>[];
  PartyInviteFrame? pendingInvite;
  String? lastBanner;
  GameEndedEvent? gameEnded;
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  /// Set by the offline demo so screens can offer its hooks.
  Object? offlineHandle;

  bool get signedIn => token != null;

  bool _disposed = false;

  @override
  void notifyListeners() {
    // A screen's dispose() may close the clients after the session itself
    // was disposed (test teardown, app exit); a late notification is noise.
    if (_disposed) return;
    super.notifyListeners();
  }

  void note(String text) {
    // A debug build also prints, so a smoke run driven from a terminal
    // (rules/manual-verification.md) can read the SDK's lines on stdout.
    if (kDebugMode) debugPrint(text);
    log.add(LogLine(text, DateTime.now()));
    if (log.length > 400) log.removeAt(0);
    notifyListeners();
  }

  void updateConfig(PlaygroundConfig next) {
    config = next;
    notifyListeners();
  }

  void signIn(ChannelToken next) {
    token = next;
    note(
      'signed in as ${next.userId} (exp ${next.expiresAt.toIso8601String()})',
    );
    notifyListeners();
  }

  AuthClient authClient() {
    // tryParse: a FormatException would quote the pasted text.
    final baseUrl = Uri.tryParse(config.authBaseUrl);
    if (baseUrl == null) throw StateError('auth base URL is not a URL');
    return AuthClient(baseUrl: baseUrl, channelId: config.authChannelId);
  }

  // ---- lobby ---------------------------------------------------------------

  Future<Hello> connectLobby() async {
    final jwt = token?.jwt;
    if (jwt == null) throw StateError('sign in first');
    await closeLobby();
    chat.clear();
    events.clear();
    lastBanner = null;
    mapLayout = MapLayout.fallback;
    final gatewayUrl = config.gatewayUrl;
    final channelId = config.channelId;
    final client = GatewayLobbyClient(
      GatewayLobbyClientOptions(
        url: gatewayUrl,
        channelId: channelId,
        token: jwt,
        logger: logger,
      ),
    );
    lobby = client;
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      client.connected.listen((hello) {
        lastBanner = null;
        // The client's own gateway and channel, not the config as edited
        // since, and the gateway's word for the user.
        final owner = (gatewayUrl, channelId, hello.userId);
        if (owner != _positionOwner) {
          position = null;
          _positionOwner = owner;
        }
        // Every hello, a reconnect included: announce where the app has you,
        // then let the gateway settle it (_onOwnEntry, the refused listener).
        _startPlacement(
          position ?? PlayerPosition(hello.zone, spawnX, spawnY, 'n'),
        );
        // Every hello: a new map version is a new URL, and the client caches
        // per URL, so an unchanged map costs nothing.
        _loadMap(client);
      }),
      client.frames.listen((frame) {
        if (frame is PosBroadcastFrame) _onOwnEntry(client, frame);
      }),
      client.stateChanges.listen((_) => notifyListeners()),
      client.snapshots.listen((_) => notifyListeners()),
      client.peerEntered.listen((_) => notifyListeners()),
      client.peerLeft.listen((_) => notifyListeners()),
      client.peerMoved.listen((_) => notifyListeners()),
      client.said.listen((s) {
        chat.add(s);
        notifyListeners();
      }),
      client.eventReceived.listen((e) {
        events.add(e);
        notifyListeners();
      }),
      client.partyChanged.listen((_) => notifyListeners()),
      client.partyInvited.listen((i) {
        pendingInvite = i;
        notifyListeners();
      }),
      client.partyDeclined.listen(
        (d) => note('${d.userId} declined the invite'),
      ),
      client.refused.listen((e) {
        note('refused: ${e.code}');
        final placement = _placement;
        if (placement == null || e.code != GatewayErrorCode.moveTooFar) return;
        // The resume `pos` was a jump from where the gateway has you; its
        // own entry, already seen or still to come, is that place.
        placement.refused = true;
        final seen = placement.seen;
        if (seen != null) _finishPlacement(seen);
      }),
      client.protocolErrors.listen((e) => note('protocol: ${e.message}')),
      client.disconnected.listen((e) {
        lastBanner = e.willReconnect
            ? 'disconnected (${e.code}): reconnecting'
            : 'disconnected (${e.code}): ${e.reason}';
        notifyListeners();
      }),
      client.stopped.listen((e) {
        lastBanner = 'stopped (${e.code}): ${e.reason}';
        notifyListeners();
      }),
    ]);
    notifyListeners();
    return client.connect();
  }

  /// Moves one step, inside the map's bounds and off its walls: the map, not
  /// this code, decides both, and the gateway enforces neither. A step out of
  /// the map is ignored rather than clamped, because a clamp after a map
  /// change could be a jump the gateway refuses.
  void move(double dx, double dy, String dir) {
    final from = position;
    if (from == null ||
        placing ||
        lobby?.state != GatewayClientState.connected) {
      return;
    }
    final layout = mapLayout;
    final x = from.x + dx;
    final y = from.y + dy;
    // How far outside the map a point is; 0 inside. A step never leaves the
    // map, but outside it (a kept or restored point from a larger map) any
    // step that does not go further out is allowed, so a wall cannot trap.
    double outside(double x, double y) =>
        [0.0, -x, x - (layout.width - 1)].reduce(max) +
        [0.0, -y, y - (layout.height - 1)].reduce(max);
    final beyond = outside(x, y);
    if (beyond > 0 && beyond > outside(from.x, from.y)) return;
    if (layout.isBlocked(x, y)) return;
    _sendPos(PlayerPosition(from.zone, x, y, dir));
  }

  /// A zone change: no distance check applies across zones.
  void changeZone(String zone) {
    final from = position;
    if (from == null ||
        placing ||
        lobby?.state != GatewayClientState.connected) {
      return;
    }
    _sendPos(PlayerPosition(zone, from.x, from.y, from.dir));
  }

  bool _sendPos(PlayerPosition p) {
    try {
      lobby?.pos(zone: p.zone, x: p.x, y: p.y, dir: p.dir);
      position = p;
      return true;
    } on GatewayClientException catch (e) {
      note('pos: ${e.code.wire}');
    } on StateError {
      note('pos: not connected');
    } on ArgumentError {
      note('pos: dir over $maxDirBytes bytes');
    } finally {
      notifyListeners();
    }
    return false;
  }

  void _startPlacement(PlayerPosition p) {
    _placement?.timer.cancel();
    // Held before the send, so no listener sees a gap in which moves pass.
    final placement = _Placement(
      p,
      Timer(placementTimeout, _placementTimedOut),
    );
    _placement = placement;
    if (!_sendPos(p)) {
      placement.timer.cancel();
      _placement = null;
      notifyListeners();
    }
  }

  /// No answer settled the placement in time, so a `pos` batch was dropped.
  /// Refusals never are: without one, the resume `pos` was accepted, whatever
  /// restore entry came first. With one and no entry, where the gateway has
  /// you is unknowable on this socket — reconnect and place again.
  void _placementTimedOut() {
    final placement = _placement;
    if (placement == null) return;
    final seen = placement.seen;
    if (!placement.refused) {
      _finishPlacement(placement.sent);
    } else if (seen != null) {
      _finishPlacement(seen);
    } else {
      _placement = null;
      note('placement lost: reconnecting');
      unawaited(connectLobby().then<void>((_) {}, onError: (Object _) {}));
    }
  }

  void _finishPlacement(PlayerPosition at) {
    _placement?.timer.cancel();
    _placement = null;
    position = at;
    notifyListeners();
  }

  /// Your own entry in a `pos` batch while placing. With moves held, it is
  /// about the resume `pos` alone: equal to it, the gateway accepted it;
  /// different, it is the restore, which stands if the `pos` is (or was)
  /// refused and is otherwise overtaken by the echo of the accepted `pos`.
  void _onOwnEntry(GatewayLobbyClient client, PosBroadcastFrame frame) {
    final placement = _placement;
    if (placement == null || frame.zone != placement.sent.zone) return;
    final self = client.hello?.userId;
    for (final p in frame.peers) {
      if (p.userId != self) continue;
      // The wire is peer data: a facing the SDK would refuse to send back is
      // dropped, not kept.
      final dir = p.dir;
      final at = PlayerPosition(
        frame.zone,
        p.x,
        p.y,
        dir != null && isDirTooLong(dir) ? null : dir,
      );
      final sent = placement.sent;
      if ((p.x == sent.x && p.y == sent.y) || placement.refused) {
        _finishPlacement(at);
      } else {
        placement.seen = at;
      }
      return;
    }
  }

  void _loadMap(GatewayLobbyClient client) {
    client.map().then(
      (document) {
        if (lobby != client) return;
        mapLayout = MapLayout.parse(document);
        note('map loaded: ${mapLayout.summary}');
      },
      onError: (Object e) {
        if (lobby != client) return;
        // The reason and status only: the body and the URL came off the wire.
        note(
          e is MapFetchException
              ? 'map fetch failed: ${e.reason} (${e.status})'
              : 'map fetch failed',
        );
      },
    );
  }

  Future<void> closeLobby() async {
    _placement?.timer.cancel();
    _placement = null;
    final client = lobby;
    lobby = null;
    // Copy then clear: a screen's dispose() and the session's own dispose()
    // may both close, and one must not iterate what the other clears.
    final subscriptions = List<StreamSubscription<Object?>>.of(_subscriptions);
    _subscriptions.clear();
    for (final s in subscriptions) {
      await s.cancel();
    }
    if (client != null) await client.close();
    notifyListeners();
  }

  void acceptInvite() {
    final invite = pendingInvite;
    if (invite == null) return;
    lobby?.party.accept(invite.partyId);
    pendingInvite = null;
    notifyListeners();
  }

  void declineInvite() {
    final invite = pendingInvite;
    if (invite == null) return;
    lobby?.party.decline(invite.partyId);
    pendingInvite = null;
    notifyListeners();
  }

  // ---- q -------------------------------------------------------------------

  final List<StreamSubscription<Object?>> _gameSubscriptions =
      <StreamSubscription<Object?>>[];

  Future<void> connectGame(String channelId, String gameId) async {
    final jwt = token?.jwt;
    if (jwt == null) throw StateError('sign in first');
    await closeGame();
    gameFrames.clear();
    gameEnded = null;
    final client = GatewayGameClient(
      GatewayGameClientOptions(
        url: config.gatewayUrl,
        channelId: channelId,
        gameId: gameId,
        token: jwt,
        logger: logger,
      ),
    );
    game = client;
    _gameSubscriptions.addAll(<StreamSubscription<Object?>>[
      client.stateChanges.listen((_) => notifyListeners()),
      client.frames.listen((f) {
        gameFrames.add(f);
        if (gameFrames.length > 100) gameFrames.removeAt(0);
        notifyListeners();
      }),
      client.refused.listen((e) => note('q refused: ${e.code}')),
      client.aborted.listen((e) {
        gameEnded = e;
        notifyListeners();
      }),
      client.finished.listen((e) {
        gameEnded = e;
        notifyListeners();
      }),
      client.stopped.listen((e) => note('q stopped (${e.code}): ${e.reason}')),
      client.protocolErrors.listen((e) => note('q protocol: ${e.message}')),
    ]);
    notifyListeners();
    await client.connect();
  }

  Future<void> closeGame() async {
    final client = game;
    game = null;
    final subscriptions = List<StreamSubscription<Object?>>.of(
      _gameSubscriptions,
    );
    _gameSubscriptions.clear();
    for (final s in subscriptions) {
      await s.cancel();
    }
    if (client != null) await client.close();
    notifyListeners();
  }

  // ---- kv ------------------------------------------------------------------

  /// The store client for the current token; a new token is a new client.
  KvStoreClient? kv;

  /// What the Announcements card shows, newest first.
  List<KvListEntry> announcements = const <KvListEntry>[];

  /// What the My settings card last read or wrote; `null` until loaded.
  KvEntry? settings;

  /// Whether the last settings read found no entry.
  bool settingsAbsent = false;

  /// Names of the two collections the guide's cases use; the offline demo
  /// seeds both, a real project creates them in the console.
  static const String announcementsCollection = 'announcements';

  /// See [announcementsCollection].
  static const String profileCollection = 'profile';

  /// Creates (or recreates) the client from the config and the token.
  KvStoreClient openKv() {
    final jwt = token?.jwt;
    if (jwt == null) throw StateError('sign in first');
    if (!config.canUseKv) throw StateError('key-value base URL is required');
    // tryParse: a FormatException would quote the pasted text.
    final baseUrl = Uri.tryParse(config.kvBaseUrl);
    if (baseUrl == null) throw StateError('key-value base URL is not a URL');
    closeKv();
    final client = KvStoreClient(
      KvStoreClientOptions(baseUrl: baseUrl, token: jwt, logger: logger),
    );
    kv = client;
    notifyListeners();
    return client;
  }

  Future<void> loadAnnouncements() async {
    final client = kv ?? openKv();
    final page = await client
        .collection(announcementsCollection)
        .list(values: true, order: KvOrder.desc);
    announcements = page.entries;
    note('announcements: ${page.entries.length} entries');
    notifyListeners();
  }

  Future<void> loadSettings() async {
    final client = kv ?? openKv();
    final entry = await client
        .collection(profileCollection)
        .mine
        .getEntry('settings');
    settings = entry;
    settingsAbsent = entry == null;
    note(
      entry == null ? 'settings: absent' : 'settings: version ${entry.version}',
    );
    notifyListeners();
  }

  /// Merges [changes] over what was last read and writes it back, then
  /// reads it again so the version shown is the stored one.
  Future<void> saveSettings(Map<String, Object?> changes) async {
    final client = kv ?? openKv();
    final current = settings?.value;
    final merged = <String, Object?>{
      if (current is Map<String, Object?>) ...current,
      ...changes,
    };
    // Write only over the version that was read: a save from another device
    // in between is a 409 (isVersionMismatch), not a lost update.
    final result = await client
        .collection(profileCollection)
        .mine
        .put(
          'settings',
          merged,
          ifMatch: settings?.version,
          ifNoneMatch: settings == null && settingsAbsent,
        );
    note(
      'settings: ${result.created == true ? 'created' : 'updated'}'
      '${result.version == null ? '' : ' version ${result.version}'}',
    );
    await loadSettings();
  }

  void closeKv() {
    kv?.close();
    kv = null;
    announcements = const <KvListEntry>[];
    settings = null;
    settingsAbsent = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(closeLobby());
    unawaited(closeGame());
    kv?.close();
    kv = null;
    super.dispose();
  }
}

/// One resume `pos` waiting for the gateway's answer.
class _Placement {
  _Placement(this.sent, this.timer);

  final PlayerPosition sent;
  final Timer timer;

  /// Refused as `move_too_far`: the next own entry settles it.
  bool refused = false;

  /// An own entry that differs from [sent]: the restore.
  PlayerPosition? seen;
}
