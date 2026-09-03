# yingyeothon_fake_gateway

An in-process stand-in for the yyt realtime gateway, for the SDK's integration
tests and the example app's offline demo. It speaks the lobby and `q` wire protocols
closely enough to drive `yingyeothon_gamebase_client` end to end over the real
transport: the bearer subprotocol handshake, `hello`, zones and the peer-map frames,
chat and events by scope, parties with the gateway's `omitempty` marshalling,
`ping`/`pong`, the documented refusal codes, and the close codes a test injects.
**It is not the gateway** — no rate limiting, no area of interest, no persistence, no
token verification — and it is `publish_to: none`.

A test (or the demo) owns both ends of the socket:

```mermaid
flowchart LR
  test["test / demo"] -- "start(), closeUser(), sendRaw()" --> fake["FakeGateway on 127.0.0.1"]
  test -- "options.url = fake.wsUrl" --> sdk["GatewayLobbyClient"]
  sdk <-- "ws://…?channel=… [bearer, token]" --> fake
  fake -- "GET /map.json" --> sdk
```

## Install

Only as a dev dependency inside this repository; `yingyeothon_fake_gateway` is never
published and imports `dart:io`, so it cannot run on web.

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

## Public API

- `FakeGateway` (`start`, `wsUrl`, `mapUrl`, `port`, `lobbyUsers`, `gameMembers`,
  `received`, `closeUser`, `sendRaw`, `sendBinary`, `shutdown`).
- `FakeGatewayOptions` (`acceptedTokens`, `tick`, `capabilities`, `partySizeMax`,
  `defaultZone`, `mapDocument`, `onGameFrame`, `maxPeers`), `GameFrameHandler`,
  `GameSession`.

## Differences from the tslib gateway-contract example

- tslib's `examples/gateway-contract` fakes the gateway inside one process for a
  contract test; this is a real loopback server, so the `web_socket_channel`
  transport, the handshake and the close codes are exercised for real.
- The `q` side has no actor: by default it echoes every frame as
  `{"type":"echo","of":…}`; `onGameFrame` scripts anything else.
