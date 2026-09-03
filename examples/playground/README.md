# playground

One Flutter app that exercises every package: sign in through the auth channel (or
paste a token), join a lobby (zone map, chat, parties), run a dungeon `q` session, and
watch the reconnect and stop banners. In a debug build an **Offline demo** starts
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

Four `--dart-define`s, all optional; the login screen lets you edit them (in memory
only, nothing is persisted):

```bash
flutter run -d linux \
  --dart-define=YYT_GATEWAY_URL=wss://gw.yyt.life \
  --dart-define=YYT_CHANNEL_ID=lobby_0123456789abcdef \
  --dart-define=YYT_AUTH_BASE_URL=https://auth.yyt.life \
  --dart-define=YYT_AUTH_CHANNEL_ID=auth_0123456789abcdef
```

Sign in with **GitHub** or **Google**: the app opens the browser with the redirect
URL from the login screen (default `http://localhost/signin`, **which must be on the
auth channel's allowlist**); a desktop build has no deep link, so the browser lands
on a connection-refused page whose address bar holds the fragment — paste that URL
back into the app. Or paste a JWT you obtained elsewhere.

## Debug hooks (`kDebugMode` only)

| Where | Hook | Effect |
| --- | --- | --- |
| Login | Offline demo | starts the fake gateway, fills the config, signs you in as `you` |
| Lobby → debug drawer | Seed peers | three extra identities join your zone and wander |
| Lobby → debug drawer | Force close 4000 / 4002 / 4004 / 4005 / 1001 | the fake closes your socket with that code |
| Dungeon | Abort (4001) / Finish (1000) | the fake closes your `q` socket |
| Everywhere | Log panel | the SDK's logger at `debug` |

`--dart-define=YYT_OFFLINE_AUTOSTART=true` starts the offline demo, enters the lobby
and seeds the peers on launch, for a smoke run or a screenshot with no input tooling.

A `--release` build has none of these.

## Layout

```
lib/
  main.dart            app + routes
  config.dart          the four dart-defines
  session.dart         ChangeNotifier owning the clients and the log
  debug/               kDebugMode-only: offline demo, seeding, forced closes
  screens/             login, lobby, dungeon
  widgets/             zone map painter, chat, party panel, banners, log panel
test/                  widget tests against the fake gateway
```
