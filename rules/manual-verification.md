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
- Chat tab: a zone message echoes back with your id; a whisper to a seeded peer is
  refused with `unknown_user` in the log panel (seeded peers are not online).
- Party tab: create, invite a seeded peer, watch the roster.
- Debug drawer → *Force close 4002*: the banner shows reconnecting, then connected;
  *Force close 4000*: stopped, no retry. *Abort q* on the dungeon screen: the Aborted
  banner.
- `flutter run -d linux --release`: the Offline demo button and the Debug drawer are
  absent.

## Debug-only hooks

All under `examples/playground/lib/debug/`, all gated by `kDebugMode`, none in a
package:

| Hook | What it does |
| --- | --- |
| Offline demo | starts the fake gateway, fills the config with its URL and a plain token |
| Seed peers | connects N extra raw sockets to the fake as `seed-1..N` and moves them |
| Force close *code* | asks the fake to close your lobby socket with `4000`…`4005`, `1000`, `1001` |
| Abort q | closes your `q` socket with `4001` |
| Log panel | the SDK's logger at `debug`, rendered in the app |

Add a hook when a verification needs a state that is slow to reach by hand; keep it
behind `kDebugMode`.

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
- Record each run in a "Last verified" line in the relevant `docs/` page or the PR
  text: commit sha, target, what was walked.
