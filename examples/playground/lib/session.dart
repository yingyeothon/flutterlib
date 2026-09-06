import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
import 'package:yingyeothon_kvstore_client/yingyeothon_kvstore_client.dart';
import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'config.dart';

/// One line the UI shows: SDK log lines and app notes share the panel.
class LogLine {
  const LogLine(this.text, this.at);
  final String text;
  final DateTime at;
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
    final client = GatewayLobbyClient(
      GatewayLobbyClientOptions(
        url: config.gatewayUrl,
        channelId: config.channelId,
        token: jwt,
        logger: logger,
      ),
    );
    lobby = client;
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      client.connected.listen((hello) {
        lastBanner = null;
        notifyListeners();
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
      client.refused.listen((e) => note('refused: ${e.code}')),
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

  Future<void> closeLobby() async {
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
