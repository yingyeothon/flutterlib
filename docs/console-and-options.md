# Console and options

## The four values

| Console field | Option | Note |
| --- | --- | --- |
| lobby channel → `wsUrl` | `GatewayClientOptions.url` | **origin only** (`wss://gw.yyt.life`); the SDK adds `?channel=…` |
| lobby channel → id | `GatewayClientOptions.channelId` | `lobby_…` for the lobby client, `q_…` for the dungeon client |
| auth channel → base URL | `AuthClient.baseUrl` | `https://auth.yyt.life` |
| auth channel → id | `AuthClient.channelId` | `auth_…` |

A `q` run also needs a `gameId`, which your game's own HTTP API hands out when it
starts a dungeon ([Dungeon](dungeon.md)).

## Every option

`GatewayClientOptions` (shared by both clients):

| Option | Default | Effect | Why you would change it |
| --- | --- | --- | --- |
| `url` | — | gateway origin | never; the console says |
| `channelId` | — | the channel | never |
| `token` | — | the channel JWT, sent as the second subprotocol | a new token means a new client |
| `webSocketFactory` | `WebSocketChannelFactory()` | opens sockets | a test double, or a transport with a proxy |
| `backoff` | 500 ms × 2 → 15 s, ±20 % | reconnect timing | a test; a game that must not stampede after a restart already has jitter |
| `maxHandshakeFailures` | 5 | consecutive closes-before-open that end the session | lower it when a bad token should fail faster |
| `logger` | `nullLogger` | ids, codes, counts | route to `debugPrint` in debug builds |

`GatewayLobbyClientOptions` adds:

| Option | Default | Effect |
| --- | --- | --- |
| `httpFetcher` | `HttpMapFetcher()` — 30 s, 16 MiB, 5 redirects | how `map()` fetches `hello.mapUrl` |
| `helloTimeoutMs` | 10 000 | how long an open socket may stay silent before it is closed and retried |

`GatewayGameClientOptions` adds `gameId`.

`AuthClient` takes `baseUrl`, `channelId`, an optional `httpClient` and a `timeout`
(30 s).

## What the console setting becomes in `hello`

| Channel setting | `hello` field | SDK |
| --- | --- | --- |
| capabilities (`pos`, `say` scopes, `party`, `event`, `debug`) | `capabilities` | `lobby.capabilities`; a `false` refuses the sender locally |
| `flushIntervalMs` | `tick` | how often `peerMoved` fires at most |
| map asset | `mapUrl` | `lobby.map()` |
| default zone | `zone` | where to send the first `pos` |
| `maxPeers`, AOI `range` | `aoi` | `hello.aoi`; how many peers a view holds |
| party size | `party.max` | `roster.max`, present once you have a roster |
