# Manual verification

Tests prove the code; a run proves the change. After the tests pass, verify in a
running build at the highest level the change reaches (`workflow.md` step 2).

## The default target: the offline demo on Linux desktop

The host is Linux, so the most directly controllable build is the desktop one, and
the example needs no credential for it:

```bash
cd examples/playground
flutter create . --platforms=linux --project-name yyt_playground --org life.yyt   # once
flutter run -d linux
```

Then **Offline demo** on the login screen. It starts `yingyeothon_fake_gateway` in
process and connects the SDK to it over the real transport. Walk the change:

- Lobby → Zone tab: move; a second identity (Debug drawer → *Seed peers*) appears and
  moves; a zone change empties and refills the map.
- Chat tab: a zone message echoes back with your id; a whisper to `seed-1` echoes
  back too (seeds are real sockets on the fake); a whisper to `nobody` is refused
  with `unknown_user` in the log panel.
- Party tab: create, invite a seeded peer, watch the roster.
- Debug drawer → *Force close 4002*: the banner shows reconnecting, then connected;
  *Force close 4000*: stopped, no retry. *Abort q* on the dungeon screen: the Aborted
  banner.
- Login → **Key-value store**: the Announcements card lists two seeded notices,
  newest first; *Save* on My settings shows `Stored: {"volume":0.5} (version 1)`,
  a second *Save* shows version 2, *Load* reads it back; the log panel shows `kv
  request` lines with a route kind and a status and never a key or the token (the
  offline token is `you`, which is also the user id, so look for `Bearer` rather
  than for the token text; `kv_screen_test.dart` does the same).
- `flutter run -d linux --release`: the Offline demo button and the Debug drawer are
  absent.

## Debug-only hooks

All under `examples/playground/lib/debug/`, all gated by `kDebugMode`, none in a
package:

| Hook | What it does |
| --- | --- |
| Offline demo | starts the fake gateway (lobby, `q` and `/kv/*`), fills the config with its URLs and a plain token |
| Seed 3 peers | connects three raw sockets to the fake as `seed-1..3` and moves them every 400 ms |
| Force close *code* | asks the fake to close your lobby socket with `4000`, `4002`, `4004`, `4005` or `1001` |
| Abort (4001) / Finish (1000) | closes your `q` socket with that code (dungeon screen) |
| Log panel | the SDK's logger at `debug`, rendered in the app |
| `--dart-define=YYT_OFFLINE_AUTOSTART=true` | on launch: offline demo, enter the lobby, seed the peers — no input needed |
| `--dart-define=YYT_OFFLINE_AUTOSTART_KV=true` | on launch: offline demo, open the key-value screen, save one settings record |

Without a UI driver (an agent, a headless box), build with the autostart define,
launch the binary, and read the log panel or stdout; that is how the ritual's "a
Linux run" is satisfied from a terminal. Add a hook when a verification needs a
state that is slow to reach by hand; keep it behind `kDebugMode`.

## Against the dev gateway

When a channel and a token are at hand, pass them and never type them into the tree:

```bash
flutter run -d linux \
  --dart-define=YYT_GATEWAY_URL=wss://gw-dev.yyt.life \
  --dart-define=YYT_CHANNEL_ID=lobby_… \
  --dart-define=YYT_AUTH_BASE_URL=https://auth-dev.yyt.life \
  --dart-define=YYT_AUTH_CHANNEL_ID=auth_…
```

Sign in through the provider (the app opens the browser) or paste a JWT you obtained
elsewhere. The recipe for minting a dev token lives in the `service` repository's smoke
scripts and is **not** written here (`security.md`). Never print the token, never
commit a channel id that is not the `0123456789abcdef` fixture.

Prove: `hello` arrives with the channel's capabilities; `pos` answers with a snapshot;
a second client (the web build, `flutter run -d chrome`, once per release) sees the
first. Web is the one platform where the subprotocol path runs in a browser; Android
or iOS is where background-resume reconnect is proven.

## Method

- Vary one thing at a time. A claim that a change restored a behaviour needs a
  negative control: the same steps on the previous commit.
- Record each run in the commit message body, one line: `Verified: offline demo on
  linux, walked <steps>` (or `Verified: dev gateway, …`). There are no PRs to carry
  it and no docs page owns it.
