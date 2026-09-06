/// The four values the console hands out plus the key-value store's base
/// URL, from `--dart-define=YYT_*`.
///
/// Nothing here is persisted; the login screen edits a copy in memory.
class PlaygroundConfig {
  const PlaygroundConfig({
    required this.gatewayUrl,
    required this.channelId,
    required this.authBaseUrl,
    required this.authChannelId,
    this.kvBaseUrl = '',
  });

  /// What the build was started with.
  static const PlaygroundConfig fromEnvironment = PlaygroundConfig(
    gatewayUrl: String.fromEnvironment('YYT_GATEWAY_URL'),
    channelId: String.fromEnvironment('YYT_CHANNEL_ID'),
    authBaseUrl: String.fromEnvironment('YYT_AUTH_BASE_URL'),
    authChannelId: String.fromEnvironment('YYT_AUTH_CHANNEL_ID'),
    kvBaseUrl: String.fromEnvironment('YYT_KV_BASE_URL'),
  );

  final String gatewayUrl;
  final String channelId;
  final String authBaseUrl;
  final String authChannelId;

  /// `https://doc.yyt.life` or its `-dev` twin; the offline demo fills it.
  final String kvBaseUrl;

  /// Enough to open a lobby socket.
  bool get canConnect => gatewayUrl.isNotEmpty && channelId.isNotEmpty;

  /// Enough to sign in.
  bool get canSignIn => authBaseUrl.isNotEmpty && authChannelId.isNotEmpty;

  /// Enough to open the key-value store, once signed in.
  bool get canUseKv => kvBaseUrl.isNotEmpty;

  PlaygroundConfig copyWith({
    String? gatewayUrl,
    String? channelId,
    String? authBaseUrl,
    String? authChannelId,
    String? kvBaseUrl,
  }) => PlaygroundConfig(
    gatewayUrl: gatewayUrl ?? this.gatewayUrl,
    channelId: channelId ?? this.channelId,
    authBaseUrl: authBaseUrl ?? this.authBaseUrl,
    authChannelId: authChannelId ?? this.authChannelId,
    kvBaseUrl: kvBaseUrl ?? this.kvBaseUrl,
  );
}
