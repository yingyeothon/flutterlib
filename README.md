# flutterlib

The Dart client libraries for the **yyt platform**: point them at the channels you
provisioned in the [yyt console](https://console.yyt.life/ui/) and a Flutter game is
talking to the realtime gateway — positions, chat, parties, and a dungeon run against
your own game actor — with the sign-in flow that gets it a token and a key-value
store for announcements and each player's own record.

Pure Dart, no Flutter import, so the same packages run on Android, iOS, desktop and
web, and `dart test` covers them without a device.

```dart
import 'package:yingyeothon_gamebase_client/yingyeothon_gamebase_client.dart';

final lobby = GatewayLobbyClient(GatewayLobbyClientOptions(
  url: 'wss://gw.yyt.life',            // the channel's wsUrl, origin only
  channelId: 'lobby_0123456789abcdef', // from the console
  token: channelJwt,                   // from your auth channel
));

final hello = await lobby.connect();   // completes on the gateway's hello
lobby.peerEntered.listen((peer) => print('${peer.userId} is here'));
lobby.pos(zone: hello.zone, x: 1, y: 2, dir: 'n'); // a new player's first pos
```

A returning player may already be placed elsewhere; the guide's
[A retained position](docs/lobby.md#a-retained-position) shows the few lines that
handle it.

## Documentation

**[Start here](docs/README.md)** — the guide is written to be enough on its own.

| | |
| --- | --- |
| [Getting started](docs/getting-started.md) | empty Flutter project to a connected, moving client |
| [Console and options](docs/console-and-options.md) | what the console hands you, and every option |
| [Authentication](docs/authentication.md) | how a client gets its channel JWT |
| [Lobby](docs/lobby.md) / [Dungeon](docs/dungeon.md) | the two channel kinds, feature by feature |
| [Key-value store](docs/kvstore.md) | announcements, a player's own record, mail and the platform clock, with the same token |
| [Leaderboards](docs/leaderboard.md) | submit a score, read a ranked page and your own rank, with the same token |
| [Friends and blocks](docs/social.md) | a player's card, friend requests, friends and blocks within the auth channel |
| [Asset bundles](docs/assets.md) | game files from the CDN, encrypted or not: a manifest, a range, a resumable download |
| [Connection lifecycle](docs/connection-lifecycle.md) | states, events, reconnect, backoff |
| [Errors](docs/errors.md) / [Troubleshooting](docs/troubleshooting.md) | every refusal, close code and symptom |
| [Flutter](docs/flutter.md) | platforms, background, debug hooks, desktop verification |
| [Examples](examples/README.md) | the playground app: offline demo, no credential needed |

## Packages

| Package | Description |
| --- | --- |
| [yingyeothon_codec](packages/yingyeothon_codec) | Bounded JSON decode and encode: length and depth caps, non-throwing core, failures that never quote the input |
| [yingyeothon_logger](packages/yingyeothon_logger) | Structured logger with a live severity threshold |
| [yingyeothon_event_broker](packages/yingyeothon_event_broker) | Type-keyed asynchronous event broker |
| [yingyeothon_gamebase_client](packages/yingyeothon_gamebase_client) | Client SDK for the yyt realtime gateway (lobby + dungeon `q`) |
| [yingyeothon_auth_client](packages/yingyeothon_auth_client) | The client half of the auth channel: config, sign-in URL, redirect, exchange, verify |
| [yingyeothon_kvstore_client](packages/yingyeothon_kvstore_client) | Client for the yyt key-value store: collections by name, `me` namespace, versions, TTL, `incr`, mail, `serverTime` |
| [yingyeothon_leaderboard_client](packages/yingyeothon_leaderboard_client) | Client for yyt leaderboards: a board by name, `submit`, a ranked `top` page, your own `score` and rank, the server's deletes |
| [yingyeothon_social_client](packages/yingyeothon_social_client) | Client for yyt social: a player's card, requests, friends and blocks, and the server key's reads and deletes |
| [yingyeothon_asset_client](packages/yingyeothon_asset_client) | Reader for asset bundles on the CDN: whole files, JSON, ranges, resumable downloads; decrypts and verifies `yyt-enc v1` |
| [yingyeothon_fake_gateway](packages/yingyeothon_fake_gateway) | In-process gateway for tests and the offline demo; never published |

The arrows are the `dependencies:` each pubspec declares; `event_broker` stands alone.

```mermaid
graph LR
  yingyeothon_gamebase_client --> yingyeothon_codec
  yingyeothon_gamebase_client --> yingyeothon_logger
  yingyeothon_logger --> yingyeothon_codec
  yingyeothon_auth_client --> yingyeothon_codec
  yingyeothon_kvstore_client --> yingyeothon_codec
  yingyeothon_kvstore_client --> yingyeothon_logger
  yingyeothon_leaderboard_client --> yingyeothon_codec
  yingyeothon_leaderboard_client --> yingyeothon_logger
  yingyeothon_social_client --> yingyeothon_codec
  yingyeothon_social_client --> yingyeothon_logger
  yingyeothon_asset_client --> yingyeothon_codec
  yingyeothon_asset_client --> yingyeothon_logger
  yingyeothon_fake_gateway --> yingyeothon_codec
```

`logger -> codec` is an edge tslib does not have: a structured log context is a
`JsonObject` so a writer renders it the same way on every platform.

## Ported from tslib and csharplib

These are Dart reimplementations of the [tslib](https://github.com/yingyeothon/tslib)
packages a game client can use, following the fixes
[csharplib](https://github.com/yingyeothon/csharplib) made on the way to Unity. tslib
has twenty packages; the rest are AWS Lambda, Redis or Node-socket server code that
cannot run on a phone. Two things are new here: `yingyeothon_auth_client`, because a
Flutter app signs in through a browser redirect and the parsing is easy to get
wrong, and `yingyeothon_fake_gateway`, so the SDK is tested end to end and the example
runs with no credential. `yingyeothon_kvstore_client` and `yingyeothon_asset_client`
are the Dart ports of tslib's `kvstore-client` and `asset-client`, with the same shape
and vocabulary in every language that has them; the key-value client is ahead of both
on the service's 2026-09-09 additions (its README says which).
`yingyeothon_leaderboard_client` and `yingyeothon_social_client` have no original
in either: the service's `/lb/*` and `/social/*` routes are newer than both
libraries, so the Dart clients came first (owner decision, 2026-10-01) and keep
the service's vocabulary for the ports to follow.

## Install

Depend on the packages by git, pinned to a release tag with `ref:`; use the same
`ref:` on every entry, or drop it from all of them to track `main`.
A package's siblings are relative path dependencies inside the same checkout, so one
git dependency per package you use is enough:

```yaml
dependencies:
  yingyeothon_gamebase_client:
    git:
      url: https://github.com/yingyeothon/flutterlib.git
      path: packages/yingyeothon_gamebase_client
      ref: v0.2.0
  yingyeothon_auth_client:
    git:
      url: https://github.com/yingyeothon/flutterlib.git
      path: packages/yingyeothon_auth_client
      ref: v0.2.0
  yingyeothon_kvstore_client:
    git:
      url: https://github.com/yingyeothon/flutterlib.git
      path: packages/yingyeothon_kvstore_client
      ref: v0.2.0
  yingyeothon_asset_client:
    git:
      url: https://github.com/yingyeothon/flutterlib.git
      path: packages/yingyeothon_asset_client
      ref: v0.2.0
  yingyeothon_leaderboard_client:
    git:
      url: https://github.com/yingyeothon/flutterlib.git
      path: packages/yingyeothon_leaderboard_client
      ref: v0.2.0
  yingyeothon_social_client:
    git:
      url: https://github.com/yingyeothon/flutterlib.git
      path: packages/yingyeothon_social_client
      ref: v0.2.0
```

Nothing is on pub.dev. The packages need the Dart SDK 3.13+ (Flutter 3.47+); on an
older toolchain pub fails to resolve them. A breaking change between tags is listed in
the package README's *Changes since* section (v0.2.0: `yingyeothon_asset_client`).

## Development

Requires the Dart SDK 3.13+ (bundled with Flutter 3.47+). Flutter is needed only for
the example.

```bash
tool/bootstrap.sh    # pub get, git hooks, tool check — once after cloning
tool/gate.sh         # format, analyze, test, coverage floor, docs gate, example
```

This repository is public, so the hooks refuse a commit that carries tool output, a
platform folder, or anything credential-shaped, and run [gitleaks][] on the staged
diff — install it, or every commit is refused. CI runs the same scan over the whole
history. See [rules/security.md](rules/security.md).

[gitleaks]: https://github.com/gitleaks/gitleaks

API design rules are in [CONVENTIONS.md](CONVENTIONS.md); durable lessons are in
[rules/](rules/index.md).

## License

MIT — see [LICENSE](LICENSE).
