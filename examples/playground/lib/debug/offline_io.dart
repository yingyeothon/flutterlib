// The io half of the offline demo: starts yingyeothon_fake_gateway in process
// and drives extra raw sockets as seeded peers. Only reachable in debug
// builds through debug_hooks.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:yingyeothon_codec/yingyeothon_codec.dart';
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';

/// What the demo's `hello.mapUrl` serves. Edit it and restart the demo: the
/// zone tab redraws from it, which is the point — a map change is a config
/// edit, not a code change.
const int demoMapWidth = 24;
const int demoMapHeight = 16;
final Map<String, Object?> demoMapDocument = <String, Object?>{
  'name': 'demo',
  'width': demoMapWidth,
  'height': demoMapHeight,
  'zones': <Object?>['Zone001', 'Zone002', 'Zone003'],
  // A wall with a door at y = 8.
  'blocked': <Object?>[
    for (var y = 2; y < 14; y++)
      if (y != 8) <Object?>[12, y],
  ],
};

/// The demo's asset bundle id, and its files: a manifest, a text file and a
/// binary of five 64 KiB segments, so a download reports progress.
const String demoBundleId = 'ab_demo';

/// The demo's leaderboard: `submit: owner`, `best`, `desc`, alltime and
/// weekly, seeded with three peers' scores.
const String demoBoard = 'race';
const String demoText = 'Hello from an encrypted asset bundle.';

Map<String, List<int>> _demoAssetFiles() {
  final big = Uint8List(300000);
  for (var i = 0; i < big.length; i++) {
    big[i] = (i * 31 + (i >> 8)) & 0xff;
  }
  return <String, List<int>>{
    'manifest.json': utf8.encode(
      Json.encode(<String, Object?>{
        'v': 1,
        'files': <Object?>['hello.txt', 'big.bin'],
      }),
    ),
    'hello.txt': utf8.encode(demoText),
    'big.bin': big,
  };
}

/// A running fake gateway plus the seeded peers attached to it.
class OfflineDemo {
  OfflineDemo._(this.gateway, this.assetKey);

  final FakeGateway gateway;

  /// A fresh key per demo, made at run time: no key text is in the tree.
  final String assetKey;
  final List<_Seed> _seeds = <_Seed>[];
  bool _seeding = false;
  Timer? _wander;

  static Future<OfflineDemo> start() async {
    final random = Random.secure();
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    final gateway = await FakeGateway.start(
      options: FakeGatewayOptions(
        tick: 100,
        mapDocument: demoMapDocument,
        // The gateway's default: a resume from a fixed spawn point into a
        // far retained position is refused here as it would be there.
        maxMoveDelta: 3,
        kvCollections: const <FakeKvCollection>[
          // The guide's two cases: a project-readable, team-written board
          // and a per-player record.
          FakeKvCollection(
            name: 'announcements',
            readScope: 'project',
            writeScope: 'team',
            entries: <String, Object?>{
              '2026-09-01': <String, Object?>{
                'title': 'Welcome to the playground',
                'body': 'This board is read-only for players.',
              },
              '2026-09-06': <String, Object?>{
                'title': 'Season 2 starts',
                'body': 'Save your settings on the other card.',
              },
            },
          ),
          FakeKvCollection(
            name: 'profile',
            readScope: 'user',
            writeScope: 'user',
          ),
        ],
        leaderboards: const <FakeLeaderboard>[
          // The guide's case: a board players write their own row to.
          FakeLeaderboard(
            name: demoBoard,
            submit: 'owner',
            rule: 'best',
            order: 'desc',
            periods: <String>['alltime', 'weekly'],
            scores: <String, int>{'seed-1': 80, 'seed-2': 60, 'seed-3': 60},
          ),
        ],
        assetBundles: <FakeAssetBundle>[
          FakeAssetBundle(id: demoBundleId, key: key, files: _demoAssetFiles()),
        ],
      ),
    );
    final text = assetKeyText(key);
    key.fillRange(0, key.length, 0);
    return OfflineDemo._(gateway, text);
  }

  String get gatewayUrl => gateway.wsUrl.toString();

  String get kvUrl => gateway.kvUrl.toString();

  String get assetUrl => gateway.assetsUrl.resolve('$demoBundleId/').toString();

  /// Connects [count] raw sockets as `seed-1..N`, drops them into [zone] and
  /// walks each one step in a random direction every 400 ms — a step, not a
  /// jump, because the demo enforces `maxMoveDelta`.
  Future<bool> seedPeers(String zone, {int count = 3}) async {
    // Once per demo: seeding again would reconnect `seed-1..N`, whose
    // positions the fake retained, and send new random points — jumps the
    // demo's maxMoveDelta refuses.
    if (_seeding) return false;
    _seeding = true;
    final random = Random();
    for (var i = 1; i <= count; i++) {
      final socket = await WebSocket.connect(
        gateway.wsUrl
            .replace(queryParameters: <String, String>{'channel': 'lobby_demo'})
            .toString(),
        protocols: <String>['bearer', 'seed-$i'],
      );
      socket.listen((_) {}, onError: (Object _) {});
      final seed = _Seed(
        socket,
        random.nextInt(demoMapWidth),
        random.nextInt(demoMapHeight),
      );
      _seeds.add(seed);
      seed.announce(zone, 's');
    }
    _wander ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
      for (final seed in _seeds) {
        if (seed.socket.readyState != WebSocket.open) continue;
        final (dx, dy, dir) = const <(int, int, String)>[
          (0, -1, 'n'),
          (0, 1, 's'),
          (1, 0, 'e'),
          (-1, 0, 'w'),
        ][random.nextInt(4)];
        seed
          ..x = (seed.x + dx).clamp(0, demoMapWidth - 1)
          ..y = (seed.y + dy).clamp(0, demoMapHeight - 1)
          ..announce(zone, dir);
      }
    });
    return true;
  }

  Future<void> closeUser(String userId, int code) =>
      gateway.closeUser(userId, code);

  Future<void> closeGame(String userId, String gameId, int code) =>
      gateway.closeUser(userId, code, gameId: gameId);

  Future<void> stop() async {
    _wander?.cancel();
    for (final s in _seeds) {
      await s.socket.close();
    }
    await gateway.shutdown();
  }
}

/// A seeded peer: a raw socket and where it stands.
class _Seed {
  _Seed(this.socket, this.x, this.y);

  final WebSocket socket;
  int x;
  int y;

  void announce(String zone, String dir) => socket.add(
    Json.encode(<String, Object?>{
      'type': 'pos',
      'zone': zone,
      'x': x.toDouble(),
      'y': y.toDouble(),
      'dir': dir,
    }),
  );
}
