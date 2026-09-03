// The web half of the offline demo: the fake gateway needs dart:io, so on
// web the demo is simply absent.

/// Placeholder with the same shape as the io implementation.
class OfflineDemo {
  static Future<OfflineDemo> start() =>
      throw UnsupportedError('the offline demo needs dart:io');

  String get gatewayUrl => '';

  Future<void> seedPeers(String zone, {int count = 3}) async {}

  Future<void> closeUser(String userId, int code) async {}

  Future<void> closeGame(String userId, String gameId, int code) async {}

  Future<void> stop() async {}
}
