// The io half of the offline demo: starts yingyeothon_fake_gateway in process
// and drives extra raw sockets as seeded peers. Only reachable in debug
// builds through debug_hooks.dart.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

/// A running fake gateway plus the seeded peers attached to it.
class OfflineDemo {
  OfflineDemo._(this.gateway);

  final FakeGateway gateway;
  final List<WebSocket> _seeds = <WebSocket>[];
  Timer? _wander;

  static Future<OfflineDemo> start() async {
    final gateway = await FakeGateway.start(
      options: const FakeGatewayOptions(tick: 100),
    );
    return OfflineDemo._(gateway);
  }

  String get gatewayUrl => gateway.wsUrl.toString();

  /// Connects [count] raw sockets as `seed-1..N`, drops them into [zone] and
  /// moves them every tick.
  Future<void> seedPeers(String zone, {int count = 3}) async {
    final random = Random();
    for (var i = 1; i <= count; i++) {
      final socket = await WebSocket.connect(
        gateway.wsUrl
            .replace(queryParameters: <String, String>{'channel': 'lobby_demo'})
            .toString(),
        protocols: <String>['bearer', 'seed-$i'],
      );
      socket.listen((_) {}, onError: (Object _) {});
      _seeds.add(socket);
      socket.add(
        Json.encode(<String, Object?>{
          'type': 'pos',
          'zone': zone,
          'x': random.nextInt(20).toDouble(),
          'y': random.nextInt(20).toDouble(),
          'dir': 's',
        }),
      );
    }
    _wander ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
      for (final socket in _seeds) {
        if (socket.readyState != WebSocket.open) continue;
        socket.add(
          Json.encode(<String, Object?>{
            'type': 'pos',
            'zone': zone,
            'x': random.nextInt(20).toDouble(),
            'y': random.nextInt(20).toDouble(),
            'dir': const <String>['n', 's', 'e', 'w'][random.nextInt(4)],
          }),
        );
      }
    });
  }

  Future<void> closeUser(String userId, int code) =>
      gateway.closeUser(userId, code);

  Future<void> closeGame(String userId, String gameId, int code) =>
      gateway.closeUser(userId, code, gameId: gameId);

  Future<void> stop() async {
    _wander?.cancel();
    for (final s in _seeds) {
      await s.close();
    }
    await gateway.shutdown();
  }
}
