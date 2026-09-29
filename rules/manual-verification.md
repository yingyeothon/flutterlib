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

- Lobby → Zone tab: the caption reads `Map demo · 24×16`, with a wall down column
  12 and chips `Zone001`–`Zone003` (the log panel says `map loaded: 24x16, 3
  zone(s), 11 blocked`); from the spawn (5, 5), seven moves right — the seventh,
  into column 12, is ignored; a second identity
  (Debug drawer → *Seed peers*) appears and moves; a zone chip empties and refills
  the map.
- Chat tab: a zone message echoes back with your id; a whisper to `seed-1` echoes
  back too (seeds are real sockets on the fake); a whisper to `nobody` is refused
  with `unknown_user` in the log panel.
- Party tab: create, invite a seeded peer, watch the roster.
- Debug drawer → *Force close 4002* after four or more moves in one direction (fewer
  would pass even with a broken resume): the banner shows reconnecting,
  then connected, you are where you were, and the log shows no `refused:
  move_too_far` (the demo enforces `maxMoveDelta` 3 against the retained position);
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
Linux run" is satisfied from a terminal:

```bash
cd examples/playground
flutter build linux --debug --dart-define=YYT_OFFLINE_AUTOSTART=true
build/linux/x64/debug/bundle/yyt_playground
```

Add a hook when a verification needs a state that is slow to reach by hand; keep it
behind `kDebugMode`.

**A desktop session can draw no frames.** Find yours with `loginctl
list-sessions`, then `loginctl show-session <that id> -p LockedHint`. When it says
`yes`, the autostart (a post-frame callback) never fires, the binary prints nothing
after the VM service line, and `flutter run -d linux` loses the VM service at once
("Lost connection to device"); `xvfb-run -a` around either did not help
(2026-09-29). **The same symptom came back with `LockedHint=no`** (2026-09-30, X11,
monitor on, `/dev/dri` readable): the window exists but stays unmapped
(`xwininfo -root -tree | grep yyt_playground`, then `xwininfo -id <window id>`
prints `Map State: IsUnMapped`), because the generated runner shows it only on the
first frame and no frame comes. Showing the window before the first frame did not
help, and a blank app failed the same way, so the host is at fault; the cause is
unknown.

Before blaming the change, run the same two commands on `HEAD` in a scratch copy
(`git archive HEAD | tar -x -C <scratch>/head`, then `flutter create .
--platforms=linux --project-name yyt_playground --org life.yyt` in its example), and
a blank app: `flutter create --platforms=linux <scratch>/blank`, then `flutter run
-d linux` in it (`<scratch>` is the session scratchpad; its window is `blank` in
`xwininfo`). If both fail the same way, commit with the matching line beside the
levels you did run, and hand the walk to the user:

- `Not run: offline demo on linux — desktop session locked (LockedHint=yes); HEAD and a blank app fail the same way`
- `Not run: offline demo on linux — window never mapped (LockedHint=no); HEAD and a blank app fail the same way`

If `HEAD` runs, the change is at fault. If only the blank app runs, `HEAD` is
already broken, which is a separate task (`workflow.md`, "A gate that was already
red"). Widget tests are not the Linux run.

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

## The key-value store against dev

With a `yyt` login on `console-dev.yyt.life` (`yyt login --profile dev --api
https://console-dev.yyt.life --device`, once), provision with the CLI, run the store's
integration test, then delete what you made (verified 2026-09-06). `<throwaway>` is a
team name of yours (`kv-it-<login>`; a team name is also its join key, so never a
real one), `<scratch>` is the session scratchpad, never a path under the tree:

```bash
export YYT_PROFILE=dev
yyt team create <throwaway> && yyt --team <throwaway> project create game
export YYT_TEAM=<throwaway> YYT_PROJECT=game
# prints the channel secret once: do not paste that output anywhere
yyt channels create --kind auth --name kv-it-auth-<yyyymmdd> --audience <throwaway> --json | jq -r .id
yyt kv create announcements --read project --write team
yyt kv create profile --read user --write user
yyt kv entry put announcements 2026-09-01 --value '{"title":"Welcome"}'
# mint a player JWT for that channel the way the service repo's smoke scripts do
# (`mintToken` in scripts/smoke/_lib.mjs; the "kv smoke" line of its
# rules/manual-verification.md) into <scratch>/jwt.txt. It needs a dev secret only
# that repo's local/ holds: without it, stop and ask the user for the file rather
# than trying another way. The user id MUST be 32 lowercase hex characters (or
# `{kind}:{id}`): `me` resolves to the JWT's sub, and a sub outside the owner
# grammar answers `400 invalid ownerId` on every /u/me route.
(cd packages/yingyeothon_kvstore_client && YYT_KV_BASE_URL=https://doc-dev.yyt.life \
  YYT_KV_TOKEN="$(cat <scratch>/jwt.txt)" dart test test/integration/round_trip_test.dart)
  # YYT_KV_ANNOUNCEMENTS / YYT_KV_PROFILE override the two collection names
yyt kv delete announcements && yyt kv delete profile && yyt channels delete auth_…
rm <scratch>/jwt.txt
```

`project delete` and `team delete` then answer `conflict` until the daily sweep
hard-purges the soft-deleted channel, 30 days after the delete. Do not work around
it: reuse the same throwaway team and project on the next run (find, then create
only when absent — a fresh team per run counts against the member's team cap and
cannot be deleted for 30 days), stamp the channel name with the date because a
deleted channel parks its name for those 30 days, and try the two deletes then. The JWT lives
in `<scratch>/jwt.txt` for the run and nowhere else: never under the tree, never
`echo`ed, never in a commit message.

## Asset bundles against dev

`yyt asset create --encrypted` and `yyt asset key show` need CLI v0.12.0 or later
(`yyt --version`; 0.15.0 was installed on 2026-09-29). If yours is older, update it;
building from the `service` repository's `cli/` with `go build -o <scratch>/yyt
./cmd/yyt` is the fallback and writes nothing into that repository. With
`YYT_PROFILE=dev`, `YYT_TEAM=<throwaway>` and `YYT_PROJECT=game` exported as in the
key-value section (reuse them; a bundle that already exists is reused too):

```bash
yyt asset create <throwaway>-assets --mode live --encrypted
yyt asset key show <throwaway>-assets > <scratch>/key.txt   # stdout only; never echo it
mkdir -p <scratch>/bundle && printf '{"v":1}' > <scratch>/bundle/manifest.json \
  && head -c 200000 /dev/urandom > <scratch>/bundle/big.bin
yyt asset sync <throwaway>-assets <scratch>/bundle --mutable manifest.json
# a line starting `rate_limited:` means the CLI's own retries ran out: wait 10 s and
# rerun (a rerun skips uploaded files); stop after 3 reruns and report it
yyt asset files <throwaway>-assets   # the URL column; <bundleId> follows /assets/
(cd packages/yingyeothon_asset_client && \
  YYT_ASSET_BASE_URL=https://dev-d.yyt.life/assets/<bundleId>/ \
  YYT_ASSET_KEY="$(cat <scratch>/key.txt)" YYT_ASSET_FILE=big.bin \
  YYT_ASSET_MANIFEST_V=1 dart test test/integration/dev_test.dart)
```

Then write `{"v":2}` into `manifest.json`, sync again, and rerun with
`YYT_ASSET_MANIFEST_V=2`: the new content, no invalidation. Afterwards `yyt asset
delete <throwaway>-assets` and `rm <scratch>/key.txt`; record `Verified: dev assets,
dev_test (v1, then v2)`.

Two checks stay with the owner until the playground reads a bundle: the same reads
in a browser (`corsSafe` against the real CDN's CORS rules; `dev_test.dart` reads
the environment through `dart:io` and cannot run there), and a resumed download of a
file over the 2 MiB default `asset.fileBytes`, which needs a platform admin to raise
the limit and a phone to kill mid-download.

## Method

- Vary one thing at a time. A claim that a change restored a behaviour needs a
  negative control: the same steps on the previous commit.
- Record each run in the commit message body, one line: `Verified: offline demo on
  linux, walked <steps>` (or `Verified: dev gateway, …`, `Verified: dev kv,
  round_trip_test`). There are no PRs to carry
  it and no docs page owns it.
