/// Builds the WebSocket URL: `{url}?channel={channelId}[&gameId={gameId}]`.
///
/// The one place a gateway URL is assembled. Existing query parameters on
/// [url] are kept; `channel` and `gameId` replace any of the same name
/// (`URLSearchParams.set` semantics, like the other SDKs). The token is
/// **not** here — it rides the subprotocol list — so the URL is safe to log.
Uri buildGatewayUrl(String url, String channelId, [String? gameId]) {
  final base = Uri.parse(url);
  final query = Map<String, String>.of(base.queryParameters)
    ..['channel'] = channelId;
  if (gameId != null) {
    query['gameId'] = gameId;
  } else {
    query.remove('gameId');
  }
  return base.replace(queryParameters: query);
}
