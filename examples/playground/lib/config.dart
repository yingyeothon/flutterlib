/// The four values the console hands out plus the key-value store's base
/// URL and an asset bundle's base URL and key, from `--dart-define=YYT_*`.
///
/// Nothing here is persisted; the login screen edits a copy in memory.
class PlaygroundConfig {
  const PlaygroundConfig({
    required this.gatewayUrl,
    required this.channelId,
    required this.authBaseUrl,
    required this.authChannelId,
    this.kvBaseUrl = '',
    this.assetBaseUrl = '',
    this.assetKey = '',
  });

  /// What the build was started with.
  static const PlaygroundConfig fromEnvironment = PlaygroundConfig(
    gatewayUrl: String.fromEnvironment('YYT_GATEWAY_URL'),
    channelId: String.fromEnvironment('YYT_CHANNEL_ID'),
    authBaseUrl: String.fromEnvironment('YYT_AUTH_BASE_URL'),
    authChannelId: String.fromEnvironment('YYT_AUTH_CHANNEL_ID'),
    kvBaseUrl: String.fromEnvironment('YYT_KV_BASE_URL'),
    assetBaseUrl: String.fromEnvironment('YYT_ASSET_BASE_URL'),
    assetKey: String.fromEnvironment('YYT_ASSET_KEY'),
  );

  final String gatewayUrl;
  final String channelId;
  final String authBaseUrl;
  final String authChannelId;

  /// `https://doc.yyt.life` or its `-dev` twin; the offline demo fills it.
  final String kvBaseUrl;

  /// `https://{cdn}/assets/{bundleId}/`; the offline demo fills it.
  final String assetBaseUrl;

  /// The bundle's `yak1.` key, empty for a plain bundle. It ships inside the
  /// app by design; never shown, logged or committed.
  final String assetKey;

  /// Enough to open a lobby socket.
  bool get canConnect => gatewayUrl.isNotEmpty && channelId.isNotEmpty;

  /// Enough to sign in.
  bool get canSignIn => authBaseUrl.isNotEmpty && authChannelId.isNotEmpty;

  /// Enough to open the key-value store, once signed in.
  bool get canUseKv => kvBaseUrl.isNotEmpty;

  /// Enough to read an asset bundle; no sign-in needed.
  bool get canUseAssets => assetBaseUrl.isNotEmpty;

  PlaygroundConfig copyWith({
    String? gatewayUrl,
    String? channelId,
    String? authBaseUrl,
    String? authChannelId,
    String? kvBaseUrl,
    String? assetBaseUrl,
    String? assetKey,
  }) => PlaygroundConfig(
    gatewayUrl: gatewayUrl ?? this.gatewayUrl,
    channelId: channelId ?? this.channelId,
    authBaseUrl: authBaseUrl ?? this.authBaseUrl,
    authChannelId: authChannelId ?? this.authChannelId,
    kvBaseUrl: kvBaseUrl ?? this.kvBaseUrl,
    assetBaseUrl: assetBaseUrl ?? this.assetBaseUrl,
    assetKey: assetKey ?? this.assetKey,
  );
}
