# yingyeothon_fake_gateway

An in-process stand-in for the yyt realtime gateway, for the SDK's integration
tests and the example app's offline demo. It speaks the lobby and `q` wire protocols
closely enough to drive `yingyeothon_gamebase_client` end to end over the real
transport: the bearer subprotocol handshake, `hello`, zones and the peer-map frames,
chat and events by scope, parties with the gateway's `omitempty` marshalling,
`ping`/`pong`, the documented refusal codes, and the close codes a test injects. The
same listener serves the state stack's `/kv/*` routes over an in-memory store, its
`/time` clock, and its `/lb/*` boards (one write to every bucket judged by rule and
order, ranks with ties, the period keys in `Asia/Seoul`, `board_full`, the server's
deletes) and its `/social/*` graph (cards, the four-state rows and every transition
the planners allow, the caps, the shared `404`, the server key's deletes), so
`yingyeothon_kvstore_client`, `yingyeothon_leaderboard_client`,
`yingyeothon_social_client` and the example's key-value, leaderboard and friends
screens run offline too. It is also the CDN for
asset bundles under `/assets/{id}/`, encrypted when given a key (the `yyt-enc v1`
encryptor in `asset_encryption.dart`), for `yingyeothon_asset_client` and the
example's asset screen.

It also reproduces the failures a client must survive, each on request: the
handshake statuses (`404` for a channel outside `channels`, `403` for a game or member
outside `games`, and `410`/`429`/`502`/`503` through `refuseHandshakes`), the 32 KB
outbound cap (`error frame_too_large` in place of the frame), the 256-frame outbound
queue of a reader that stopped draining (`holdOutbound`: the oldest `pos` batch is
dropped first, a queue of nothing but control frames closes with `4005`), an actor
that stops consuming (`stallGame`: depth over 200, or over 20 for more than 5 s,
closes every member with `4001`), `capability_off` for every `party.*` type, the
8 KB event payload (`too_long`), `move_too_far` past `maxMoveDelta` (off unless set;
the gateway's default is 3), and a snapshot of the `maxPeers` nearest others. Like
the gateway it retains your position for the next socket and, with `pos` on,
restores it before reading anything you send, then sends the snapshot before the
party roster and flushes your own entry in the `pos` batch after every zone entry.
A `q` disconnect pushes a `leave` that counts toward a stalled actor's depth.

**It is not the gateway** — no rate limiting and no `4003`, no `aoi.range` box and no
per-receiver view (`enter` and `pos` go to the whole zone; only the snapshot is
capped at `maxPeers`), no `4002` idle close, no persistence beyond the process (a
retained position and a party never expire), no token verification, and no `4001`
handshake for a game still being aborted. Byte caps are measured on Dart's JSON,
which does not escape `<`, `>` and `&` as Go does, so a frame full of them fits a
little more. It is `publish_to: none`.

A test (or the demo) owns both ends of the socket:

```mermaid
flowchart LR
  test["test / demo"] -- "start(), closeUser(), sendRaw()" --> fake["FakeGateway on 127.0.0.1"]
  test -- "options.url = fake.wsUrl" --> sdk["GatewayLobbyClient"]
  sdk <-- "ws://…?channel=… [bearer, token]" --> fake
  fake -- "GET /map.json" --> sdk
  test -- "options.kvCollections; kv.valueText()" --> fake
  kv["KvStoreClient"] <-- "/kv/{col}/… Authorization: Bearer" --> fake
  test -- "options.leaderboards; lb.scoreOf()" --> fake
  lb["LeaderboardClient"] <-- "/lb/{board}/… Authorization: Bearer" --> fake
  social["SocialClient"] <-- "/social/… Authorization: Bearer" --> fake
  test -- "options.assetBundles" --> fake
  assets["AssetBundleClient"] <-- "/assets/{id}/… Range, If-Range" --> fake
```

## Install

Only as a dev dependency inside this repository; `yingyeothon_fake_gateway` is never
published and imports `dart:io`, so it cannot run on web — all but
`asset_encryption.dart`, which a browser test may import.

```yaml
dev_dependencies:
  yingyeothon_fake_gateway: ^0.1.0   # workspace-resolved
```

## Usage

```dart
import 'package:yingyeothon_fake_gateway/yingyeothon_fake_gateway.dart';
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

final gw = await FakeGateway.start();
final client = GatewayLobbyClient(GatewayLobbyClientOptions(
  url: gw.wsUrl.toString(),
  channelId: 'lobby_0123456789abcdef',
  token: 'alice', // any non-empty token; its text (or its JWT `sub`) is the user id
));
await client.connect();
await gw.closeUser('alice', 4002); // the SDK reconnects
await gw.shutdown();
```

Identity comes from the token: a JWT-shaped token yields its `sub`, anything else is
its own user id, so two clients with tokens `alice` and `bob` see each other.

The key-value routes need collections, declared the way the console would create
them; a token starting with `yds.` is the game server (the fake checks only the
prefix; the service verifies the key and binds it to a project), anything else a
player whose user id — and therefore whose `owner` in every listing row — is the
token text itself:

```dart
final gw = await FakeGateway.start(
  options: const FakeGatewayOptions(
    kvCollections: <FakeKvCollection>[
      FakeKvCollection(name: 'announcements', readScope: 'project', writeScope: 'team',
          entries: <String, Object?>{'2026-09-01': <String, Object?>{'title': 'Welcome'}}),
      FakeKvCollection(name: 'profile', readScope: 'user', writeScope: 'user'),
    ],
  ),
);
final kv = KvStoreClient(KvStoreClientOptions(baseUrl: gw.kvUrl, token: 'alice'));
await kv.collection('profile').mine.put('settings', {'volume': 0.5});
gw.kv.valueText('profile', 'settings', owner: 'alice'); // '{"volume":0.5}'
```

An asset bundle is its files, encrypted at start when given a 32-byte key:

```dart
final key = Uint8List.fromList(List<int>.generate(32, (i) => i)); // build it, never paste one
final gw = await FakeGateway.start(
  options: FakeGatewayOptions(assetBundles: <FakeAssetBundle>[
    FakeAssetBundle(id: 'ab_demo', key: key, files: {'manifest.json': utf8.encode('{"v":1}')}),
  ]),
);
final assets = AssetBundleClient(AssetBundleClientOptions(
  baseUrl: gw.assetsUrl.resolve('ab_demo/').toString(),
  key: assetKeyText(key),
));
await assets.readJson('manifest.json'); // {v: 1}
```

The CDN answers `GET` and `HEAD`, one `Range`, `If-Range` against its md5 `ETag`,
`416` past the end and `403` for anything missing; it sends no CORS headers,
ignores `Cache-Control`, and cannot replace a file while it runs.

## Public API

- `FakeGateway` (`start`, `wsUrl`, `mapUrl`, `kvUrl`, `kv`, `lb`, `social`, `assetsUrl`, `port`,
  `lobbyUsers`,
  `gameMembers`, `received`, `closeUser`, `sendRaw`, `sendBinary`,
  `refuseHandshakes`, `stallGame`, `holdOutbound`, `releaseOutbound`, `shutdown`).
- `FakeGatewayOptions` (`acceptedTokens`, `tick`, `capabilities`, `partySizeMax`,
  `defaultZone`, `mapDocument`, `onGameFrame`, `maxPeers`, `kvCollections`,
  `leaderboards`, `socialProfiles`, `assetBundles`, `channels`, `games`, `clock`, `maxMoveDelta`), `GameFrameHandler`,
  `GameSession`.
- `FakeKvCollection` (`name`, `id`, `readScope`, `writeScope`, `encrypted`,
  `maxEntries`, `maxEntriesPerOwner`, `entries`, `ownerEntries`), `FakeKvStore`
  (`valueText`, `handles`, `handle`).
- `FakeLeaderboard` (`name`, `id`, `submit`, `rule`, `order`, `periods`, `maxEntries`,
  `scores`), `FakeLeaderboardStore` (`scoreOf`, `periodKey`, `periodEndsAt`,
  `periodNames`, `handles`, `handle`).
- `FakeSocialProfile` (`owner`, `displayName`, `avatar`), `FakeSocialStore`
  (`relation`, `displayNameOf`, the caps, `handles`, `handle`).
- `FakeAssetBundle` (`id`, `objects`; built from `files` and an optional `key`).
- `encryptAsset`, `assetKeyText` — also alone in `asset_encryption.dart`, which
  imports no `dart:io`, for a test that runs in a browser.

## Differences from the tslib gateway-contract example

- tslib's `examples/gateway-contract` fakes the gateway inside one process for a
  contract test; this is a real loopback server, so the `web_socket_channel`
  transport, the handshake and the close codes are exercised for real.
- The `q` side has no actor: by default it echoes every frame as
  `{"type":"echo","of":…}`; `onGameFrame` scripts anything else.
- The kv store follows `services/state`'s routes (the four scopes, both namespaces —
  per owner when either scope is `user` — versions that keep climbing, conditional
  writes, TTL, `incr` with `min`/`max`, mail and the writer stamp, cursors, the
  `409` reasons, and `GET /time`) (a version survives expiry, not a delete) but
  admits any plain segment as an owner id, because its identities are token texts
  rather than 32-hex user ids — so a mail writer's id is not held to the owner
  grammar and a player's stamp is its token text — and stores values in the clear
  whatever `encrypted` says.
- The boards follow `services/state/src/leaderboard.ts` (the board before the
  credential rule, `submit`, every bucket judged by `rule` × `order`, `board_full`
  for the whole write, `1 + count(better)` ranks with ties by owner in the scan's
  direction, the KST period keys, `limit` clamped and `offset` refused past 1,000,
  the server-only deletes with a 500-row clear batch) but, like the kv store, admit
  any plain segment as an owner, keep no past buckets and never sweep.
- The graph follows `services/state/src/social.ts` and the planners in
  `packages/console-db/src/social.ts` (a card at both ends, the shared `404`, a
  decline kept as a cooldown the sender sees as pending, a block that drops the
  peer's row but never their block, an unblock that restores a cooldown, mutual
  requests settling at once with a `200`, the caps, a card delete that spares
  others' blocks, the server key's reads, card writes and relation deletes) but
  admits any plain segment as a player id or a profile owner alike (the service
  keeps the two grammars apart), authenticates before it routes (the service
  answers a bad path or method before the credential), moves a row's `since` on
  every write where the service keeps `created_at`, never expires a request and
  never sweeps.
- `GET /kv/{col}` refuses a player only when both scopes are `team` or `server`, as
  the service's route comment says (its docs still name `team`/`team` only); the
  deployed route code also refuses a player on any collection without a `project`
  scope (`user`/`user` included), which reads as a service defect and is not copied.
