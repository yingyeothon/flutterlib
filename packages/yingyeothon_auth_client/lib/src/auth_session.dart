import 'package:yingyeothon_logger/yingyeothon_logger.dart';

import 'auth_client.dart';
import 'internal/auth_session_impl.dart';

/// Opt-in token storage implemented by the host app. Never use shared web storage.
abstract interface class AuthTokenStorage {
  /// Reads a saved JWT, or null.
  Future<String?> load();

  /// Persists a JWT in secure platform storage. Never log the argument.
  Future<void> store(String token);

  /// Removes the saved JWT.
  Future<void> clear();
}

/// Safe session lifecycle/clock failure.
final class AuthSessionException implements Exception {
  /// Creates a failure with a fixed code.
  const AuthSessionException(this.code);

  /// unavailable, signed_out, invalid_state or cancelled.
  final String code;
  @override
  String toString() => 'AuthSessionException($code)';
}

/// Options for an engine-free auth session.
final class AuthSessionOptions {
  /// Creates options; no platform-specific default storage or login is assumed.
  const AuthSessionOptions({
    required this.fetchServerTime,
    this.signIn,
    this.storage,
    this.monotonicMilliseconds,
    this.logger,
  });

  /// Server clock provider; use KvStoreClient.fetchServerTime from the host/kit.
  final Future<DateTime> Function() fetchServerTime;

  /// Host login flow; receives and verifies its own redirect nonce.
  final Future<ChannelToken> Function()? signIn;

  /// Opt-in storage. Null keeps the credential only in memory.
  final AuthTokenStorage? storage;

  /// Monotonic time source for tests. Null uses a running Stopwatch.
  final int Function()? monotonicMilliseconds;

  /// Safe diagnostics, default nullLogger.
  final Logger? logger;
}

/// Identity and platform time shared by every kit module.
abstract interface class AuthSession {
  /// Creates a signed-out session; does not read storage automatically.
  factory AuthSession(AuthSessionOptions options) = AuthSessionImpl;

  /// Current JWT, or null; never log or persist on shared web origins.
  String? get token;

  /// Current service user id, or null.
  String? get userId;

  /// Token expiry as epoch seconds, not milliseconds.
  int? get expiresAt;

  /// Any identity replacement or sign-out, delivered synchronously.
  Stream<ChannelToken?> get changed;

  /// Fired once per adopted token at exp minus ten minutes.
  Stream<void> get expiring;

  /// A 401/expiry/explicit sign-out stops the current identity once.
  Stream<void> get signedOut;

  /// Uses the host's login adapter.
  Future<ChannelToken> signIn();

  /// Reads JWT claims without checking its signature; services authenticate requests.
  Future<ChannelToken> fromToken(String jwt);

  /// Loads from the injected secure storage.
  Future<ChannelToken?> restore();

  /// Stops identity/timers immediately, then clears storage.
  Future<void> signOut();

  /// Synchronizes the server clock; previous anchors survive failed refreshes.
  Future<void> synchronize();

  /// Epoch milliseconds derived from server time and a monotonic midpoint.
  /// Throws unavailable until successful clock synchronization.
  int now();

  /// Clears memory and timers, preserving opt-in storage for the next launch.
  Future<void> close();
}
