# playground

One Flutter app that exercises every package: sign in through the auth channel (or
paste a token), join a lobby (zone map, chat, parties), run a dungeon `q` session,
watch the reconnect and stop banners, and read announcements and save your settings
in the key-value store. In a debug build an **Offline demo** starts
`yingyeothon_fake_gateway` in the process, so all of it runs with no credential and no
network.

## Build

Platform folders are not committed. Inject the ones you want, then run:

```bash
cd examples/playground
flutter create . --platforms=linux --project-name yyt_playground --org life.yyt
flutter run -d linux
```

`flutter create .` adds `linux/` (or `android/`, `ios/`, `macos/`, `windows/`, `web/`)
and touches nothing that is committed: `lib/`, `test/`, `pubspec.yaml`, `README.md`,
`analysis_options.yaml`. The offline demo is not available on web (the fake gateway
needs `dart:io`); everything else is.

## Configure

Five `--dart-define`s, all optional; the login screen lets you edit them (in memory
only, nothing is persisted):

```bash
flutter run -d linux \
  --dart-define=YYT_GATEWAY_URL=wss://gw.yyt.life \
  --dart-define=YYT_CHANNEL_ID=lobby_0123456789abcdef \
  --dart-define=YYT_AUTH_BASE_URL=https://auth.yyt.life \
  --dart-define=YYT_AUTH_CHANNEL_ID=auth_0123456789abcdef \
  --dart-define=YYT_KV_BASE_URL=https://doc.yyt.life
```

The **Key-value store** screen expects two collections in your project, created in
the console: `announcements` (readScope `project`, writeScope `team`) and `profile`
(readScope `user`, writeScope `user`). The offline demo seeds both.

Sign in with **GitHub** or **Google**: the app opens the browser with the redirect
URL from the login screen (default `http://localhost/signin`, **which must be on the
auth channel's allowlist**); a desktop build has no deep link, so the browser lands
on a connection-refused page whose address bar holds the fragment — paste that URL
back into the app. Or paste a JWT you obtained elsewhere.

## The map

The zone tab draws what `lobby.map()` returned, fetched again on every `hello` (the
SDK caches it per URL). The playground understands one shape of its own — the SDK
does not care what the document holds:

```json
{ "name": "demo", "width": 24, "height": 16,
  "zones": ["Zone001", "Zone002", "Zone003"],
  "blocked": [[12, 2], [12, 3]] }
```

`width` and `height` (1–64, default 20) size the grid and bound your moves; each
distinct `zones` entry, up to 16, becomes a chip that changes zone; a `blocked` cell
is drawn filled and refused as a move target — by the app: the gateway enforces
neither. A zone is sent back on the wire exactly as written, so one the app could
not show as written (over 64 bytes, a control, format, bidi or invisible character)
is dropped, never shortened; a `name` over 32 characters or with such a character
falls back to `unnamed`. Anything else missing or
malformed falls back per field. The spawn point (5, 5) is sent before the map
arrives and is not checked against it.

The offline demo serves `demoMapDocument` from `lib/debug/offline_io.dart`: edit it
and hot-restart (or rerun) the app to watch the tab redraw — a hot reload keeps the
old value.

## Your position

The session, not the screen, keeps the position it last sent — for one user on one
channel of one gateway — and announces it on every `connected` (the first, a
reconnect, a lobby screen opened again) and holds your moves until the gateway
answers: an own entry equal to it confirms it, a different one is the restore, which
stands if a `move_too_far` refuses the announcement. After 5 s without an answer a
batch was dropped: it keeps what it sent, or after a refusal the restore it saw, or
reconnects when it saw none. That is the
[retained position](../../docs/lobby.md#a-retained-position) rule: the gateway puts
you back where it last wrote you, and a same-zone `pos` from a fixed spawn point is
refused as `move_too_far`. The offline demo enforces the gateway's default
`maxMoveDelta` of 3, so the rule holds there too; its seeded peers walk one step at
a time for the same reason, and *Seed peers* seeds them once per demo.

## Debug hooks (`kDebugMode` only)

| Where | Hook | Effect |
| --- | --- | --- |
| Login | Offline demo | starts the fake gateway (lobby, `q` and `/kv/*`), fills the config, signs you in as `you` |
| Lobby → debug drawer | Seed peers | three extra identities join your zone and wander |
| Lobby → debug drawer | Force close 4000 / 4002 / 4004 / 4005 / 1001 | the fake closes your socket with that code |
| Dungeon | Abort (4001) / Finish (1000) | the fake closes your `q` socket |
| Everywhere | Log panel | the SDK's logger at `debug` |

`--dart-define=YYT_OFFLINE_AUTOSTART=true` starts the offline demo, enters the lobby
and seeds the peers on launch, for a smoke run or a screenshot with no input tooling;
`--dart-define=YYT_OFFLINE_AUTOSTART_KV=true` does the same for the key-value screen
and saves one settings record.

A `--release` build has none of these.

## Layout

```
lib/
  main.dart            app + routes
  config.dart          the five dart-defines
  session.dart         ChangeNotifier owning the clients, the map and the log
  map_layout.dart      the playground's reading of the map document
  debug/               kDebugMode-only: offline demo, seeding, forced closes
  screens/             login, lobby, dungeon, key-value store
  widgets/             zone map painter, chat, party panel, banners, log panel
test/                  widget tests against the fake gateway
```
