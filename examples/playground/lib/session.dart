import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yingyeothon_auth_client/yingyeothon_auth_client.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';
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

  AuthClient authClient() => AuthClient(
    baseUrl: Uri.parse(config.authBaseUrl),
    channelId: config.authChannelId,
  );

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

  @override
  void dispose() {
    _disposed = true;
    unawaited(closeLobby());
    unawaited(closeGame());
    super.dispose();
  }
}
