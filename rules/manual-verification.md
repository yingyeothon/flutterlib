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
  (Debug drawer → *Seed peers*; the drawer opens from the bug icon at the end of
  the app bar) appears and moves; a zone chip empties and refills the map.
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
- Login → **Leaderboard**: the board card reads `submit owner, rule best, order
  desc, periods alltime/weekly` and `alltime · 3 row(s)` with `seed-1` at `#1`;
  *Submit* with the default 70 shows `Stored 70, rank 2 of 4`; a second submit of
  `10` leaves that line as it is, and the log panel shows `lb request` lines with a route kind and
  a status and never a `Bearer`.
- Login → **Friends**: `No card yet`; type `demoFriendId` (32 `a`s) into the
  player id field, then *Ask* before a card shows `set your card first (409)`;
  *Save* shows `Card: Player (heroes/mage)`; *Ask* again shows `0 waiting for me,
  1 sent`; the log panel shows `social request` lines with a route kind and a
  status and never a `Bearer` or a name.
- Login → **Asset bundle** (enabled without sign-in): the first line reads `An
  encrypted bundle: every 64 KiB segment is verified…`, the manifest card shows `{"v":1,"files":["hello.txt","big.bin"]}`, *Read*
  shows `Hello from an encrypted asset bundle.`, *Download* fills the bar and ends
  at `Downloaded 300000 bytes`; the log panel shows `asset request` lines and never
  the key (it is random per demo, so look for `yak1.` and for a long base64url run).
- `flutter run -d linux --release`: the Offline demo button and the Debug drawer are
  absent.

## Debug-only hooks

All under `examples/playground/lib/debug/`, all gated by `kDebugMode`, none in a
package:

| Hook | What it does |
| --- | --- |
| Offline demo | starts the fake gateway (lobby, `q`, `/kv/*`, the `race` board under `/lb/*`, three cards under `/social/*` and an encrypted bundle under `/assets/*` with a key made at start), fills the config with its URLs, that key and a plain token |
| Seed 3 peers | connects three raw sockets to the fake as `seed-1..3` and moves them every 400 ms |
| Force close *code* | asks the fake to close your lobby socket with `4000`, `4002`, `4004`, `4005` or `1001` |
| Abort (4001) / Finish (1000) | closes your `q` socket with that code (dungeon screen) |
| Log panel | the SDK's logger at `debug`, rendered in the app |
| `--dart-define=YYT_OFFLINE_AUTOSTART=true` | on launch: offline demo, enter the lobby, seed the peers — no input needed |
| `--dart-define=YYT_OFFLINE_AUTOSTART_KV=true` | on launch: offline demo, open the key-value screen, save one settings record |
| `--dart-define=YYT_OFFLINE_AUTOSTART_LB=true` | on launch: offline demo, open the leaderboard screen, submit one score |
| `--dart-define=YYT_OFFLINE_AUTOSTART_SOCIAL=true` | on launch: offline demo, open the friends screen, set a card, ask the first seeded card's owner |

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

**A desktop session can draw no frames.** The symptoms: nothing is printed after
the VM service line; `flutter run -d linux` says "Lost connection to device";
`xwininfo -root -tree | grep yyt_playground` finds the window and `xwininfo -id
<that id>` says `Map State: IsUnMapped` (the runner maps it on the first frame).
Nothing below writes outside `<scratch>`, the session scratchpad: no `sudo`, no
`apt`, nothing under `~/.cache`, `~/.config` or `/etc`. A host fix is named in the
commit's `Verified:` or `Not run:` line and to the user, and left to the owner. Two
host faults have produced this picture; decide which, in order:

1. **The session is locked.** `loginctl list-sessions`, take the id whose `SEAT`
   is `seat0`, then `loginctl show-session <that id> -p LockedHint`. `yes` means
   no frame can come (`xvfb-run -a` did not help, 2026-09-29): hand the walk back
   with the first `Not run:` line below.
2. **The main thread spins in fontconfig** (2026-09-30 and 2026-10-01; a reboot
   does not clear it). In `examples/playground`, launch the autostart build in the
   background (`build/linux/x64/debug/bundle/yyt_playground &`), read `ps -o
   stat,time -p $(pgrep -n yyt_playground)` twice a few seconds apart — state `R`
   and a climbing time is a spin — then `pkill -x yyt_playground`. Attaching is
   refused (`/proc/sys/kernel/yama/ptrace_scope` is 1), so run the binary under
   gdb and interrupt it:

   ```bash
   timeout -s INT 12 gdb -q --batch -ex run -ex 'thread 1' -ex 'bt 40' \
     --args build/linux/x64/debug/bundle/yyt_playground
   ```

   A stack with `FcPatternGetString` under `gtk_widget_realize` is this fault. On
   this host it came from foreign `*.cache-12` files with `cache-9`, `-10` and
   `-11` symlinks in `~/.cache/fontconfig`, which the system fontconfig 2.15 cannot
   read; without `gdb`, `ls -l ~/.cache/fontconfig` showing those is the same
   finding. The owner removed them on 2026-10-01 and the window mapped again with
   no workaround, so a recurrence means something wrote them back: name it in the
   commit's `Verified:` or `Not run:` line and to the user. Work around it with a
   config whose cache lives in `<scratch>` (`/etc/fonts/fonts.conf` itself names
   the broken cache dir, so include only `conf.d`), written to
   `<scratch>/fonts.conf`:

   ```xml
   <?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd">
   <fontconfig>
     <dir>/usr/share/fonts</dir><dir>/usr/local/share/fonts</dir>
     <cachedir><scratch>/fc-cache</cachedir>
     <include ignore_missing="yes">/etc/fonts/conf.d</include>
   </fontconfig>
   ```

   Replace `<scratch>` in the `cachedir` line with the absolute scratchpad path
   before writing the file. Then `FONTCONFIG_FILE=<scratch>/fonts.conf fc-cache`
   (the variable on `fc-cache` too, or it writes the host cache) and the same
   variable in front of the binary or of `flutter run -d linux`. The window maps within twenty seconds;
   walk under it and say so in the `Verified:` line (fonts are not what the walk
   proves; without a UI driver, `<steps>` is `autostart only`). If it still does
   not map, the workaround is not enough: use the third `Not run:` line. The host
   fix — deleting those cache files and links, then `fc-cache -f` — is the owner's:
   name it, do not run it.

If the picture matches neither, run the same build and launch on `HEAD` in a scratch
copy (`mkdir -p <scratch>/head && git archive HEAD | tar -x -C <scratch>/head`,
then `flutter create . --platforms=linux --project-name yyt_playground --org
life.yyt` in its example) and
on a blank app (`flutter create --platforms=linux <scratch>/blank`, then `flutter
run -d linux` in it; its window is `blank` in `xwininfo -root -tree`). If both fail
the same way, commit with the matching line beside the levels you did run, and hand
the walk to the user:

- `Not run: offline demo on linux — desktop session locked (LockedHint=yes)`
- `Not run: offline demo on linux — window never mapped (LockedHint=no, not fontconfig); HEAD and a blank app fail the same way`
- `Not run: offline demo on linux — main thread spins in fontconfig; a scratch FONTCONFIG_FILE did not map the window`

The `Verified:` form when the workaround carried the walk (no path: the scratchpad
path names the account and the session):

- `Verified: offline demo on linux under a scratch FONTCONFIG_FILE (host fontconfig cache still broken), walked <steps>`

If `HEAD` runs, the change is at fault. If only the blank app runs, `HEAD` is
already broken, which is a separate task (`workflow.md`, "A gate that was already
red"). Widget tests are not the Linux run.

**Driving the window without `xdotool`.** The host has no `xdotool`, `xte` or
`ydotool`. Use XTEST through `python-xlib` in a scratch venv (`python3 -m venv
<scratch>/venv && <scratch>/venv/bin/pip install python-xlib`, which needs the
network) from a ~20-line helper under `<scratch>`: `d = Xlib.display.Display()`,
`xtest.fake_input(d, X.MotionNotify, x=x, y=y)`, `X.ButtonPress` / `X.ButtonRelease`
with detail 1, `X.KeyPress` / `X.KeyRelease` with
`d.keysym_to_keycode(XK.string_to_keysym(name))` where `name` is a keysym name
(letters and digits are their own; `-` is `minus`, space `space`, Enter
`Return`), and `d.sync()` after each. Take screenshots with ImageMagick into
`<scratch>` — `import -window root <scratch>/root.png` once to find the title
bar's maximize button, then `import -window <window id> <scratch>/app.png` — and
read them with the `Read` tool; maximize first so screenshot coordinates stay reproducible.
The desktop facts that shape the walk (click a tab, open the drawer from its
button) are in `flutter.md`, "Example mechanics".

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
a second client (the web build, once per release) sees the first. Web is the one
platform where the subprotocol path runs in a browser; Android or iOS is where
background-resume reconnect is proven. Both run from this host with the Chrome
extension and the Android emulator: "Web and Android against dev" below.

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
  && head -c 200000 /dev/urandom > <scratch>/bundle/big.bin \
  && printf 'hello' > <scratch>/bundle/hello.txt   # the example screen reads it
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

The browser and emulator checks — the **Asset bundle** screen in Chrome (`corsSafe`
against the real CDN's CORS rules; `dev_test.dart` reads the environment through
`dart:io` and cannot run there) and a resumed download over the default
`asset.fileBytes` — are steps 3 and 6 of the next section.

## Web and Android against dev

Prerequisites, each a `Not run:` line (the list at the end) when missing: the kv and
asset sections above done first and stopped before their delete and `rm` lines,
which step 7 runs (so the login, `<throwaway>`, both collections, the encrypted
bundle with its `key.txt`, the auth channel `kv-it-auth-<yyyymmdd>` and a JWT for it
in `<scratch>/jwt.txt` are all still there); the Claude in Chrome extension
(`mcp__claude-in-chrome__*`); an Android emulator (`flutter emulators` lists them,
`<avd>` below; it needs `/dev/kvm`); `python3 -c 'import tkinter'`. Walked
2026-10-01 (Flutter 3.47.5, CLI 0.15.0); in this order:

1. **The lobby.** A second between console writes; `rate_limited` means retry that
   one. `--map-url` refuses a live or an encrypted bundle (`bad_request`), so the
   map goes in a plain versioned bundle: `<scratch>/map/map.json` in the shape of
   `examples/playground/README.md` ("The map") with `"zones": ["zone001", "zone002",
   "zone003"]`, then `yyt asset create <throwaway>-map --mode versioned`, `yyt asset
   sync <throwaway>-map <scratch>/map --version 1`, and the `map.json` row's URL from
   `yyt asset files <throwaway>-map 1`. Then `yyt channels create --kind lobby --name
   web-lobby-<yyyymmdd> --auth-channel <the kv auth channel id> --cap-say zone
   --cap-say party --cap-say user --max-move-delta 3 --zone zone001 --map-url <that
   URL> --json` (no secret in a lobby's output; `--zone` must match `[a-z0-9_-]`, so
   the map's zones are lowercase and the spawn zone is a chip). Mint a second JWT
   for the same auth channel into `<scratch>/jwt2.txt` the way the first was.
2. **The defines file.** `<scratch>/defines.json` is a JSON object with the seven
   `YYT_*` keys of `examples/playground/README.md`: the lobby's `wsUrl` origin and
   id, `https://auth-dev.yyt.life` and the auth id, `https://doc-dev.yyt.life`, the
   encrypted bundle's `https://dev-d.yyt.life/assets/<bundleId>/` and its key —
   composed in the shell, never by reading `key.txt` into a tool argument: `jq -n
   --rawfile k <scratch>/key.txt --arg ws … '{YYT_ASSET_KEY: ($k | rtrimstr("\n")),
   YYT_GATEWAY_URL: $ws, …}' > <scratch>/defines.json`. Every build below takes
   `--dart-define-from-file=<scratch>/defines.json`, which bakes those values into
   `build/`; step 7 removes them.
3. **Chrome.** In `examples/playground`: `flutter create . --platforms=web
   --project-name yyt_playground --org life.yyt`, `flutter build web
   --dart-define-from-file=…`, then `setsid nohup python3 -m http.server 8087
   --bind 127.0.0.1 --directory build/web >/dev/null 2>&1 & echo $!` (a plain `&`
   dies with the tool's shell; keep the pid), and open `http://127.0.0.1:8087/` in the
   user's Chrome through the extension (`flutter run -d chrome` starts a profile the
   extension cannot drive). Drive the page with `computer` screenshots and clicks
   only — the Flutter canvas has no element refs, and the network, console and page
   readers would put the bearer subprotocol or the pasted token in the transcript.
   The click frame may not match the screenshot's pixels: hover at a known point,
   take a screenshot (it shows the cursor), and scale every click by the ratio.
   **Asset bundle** first (no sign-in): the manifest card, *Read* shows `hello`,
   *Download* ends at `Downloaded 200000 bytes`, the log has `head` and `segments`
   lines and no `yak1.`. Then sign in: leave both auth fields as the defines file
   filled them (the **Auth base URL** and the **Auth channel id** — `canSignIn` needs
   both), so *Use this token* calls `verify` on the service. The token goes through the host
   clipboard, never through a tool's text argument (that is the transcript): this
   host has no `xclip`, so `<scratch>/clip.py` is `import sys, tkinter as tk; r =
   tk.Tk(); r.withdraw(); r.clipboard_clear();
   r.clipboard_append(open(sys.argv[1]).read().strip()); r.mainloop()`, started
   as `setsid nohup python3 <scratch>/clip.py <scratch>/jwt.txt >/dev/null 2>&1 &
   echo $!`; it owns the selection only while it runs, so `kill <pid>` afterwards.
   Click the JWT field, `ctrl+v`, *Use this token*. Expect `Signed in as <32 hex>`
   (the same shape as on Android; write the shape, not the value, in the commit
   line). `Signed in as (unverified)` means `canSignIn` was false — an auth field
   empty in `defines.json` or cleared by hand — and counts as a pass only on the
   fallback below. `sign-in failed: AuthFailure(network)` is a CORS refusal, a
   timeout or a wrong base URL: check the preflight from the shell only — never with
   the extension's network or console readers (the page's own request carries the JWT
   in `Authorization`) — with no token: `curl -si -X OPTIONS -H 'Origin:
   http://127.0.0.1:8087' -H 'Access-Control-Request-Method: GET' -H
   'Access-Control-Request-Headers: authorization'
   https://auth-dev.yyt.life/c/<ch>/verify` (`<ch>` is `YYT_AUTH_CHANNEL_ID` from
   `defines.json`) must answer `204` with `access-control-allow-headers` containing
   `authorization`. A `204` proves only CORS (the handler answers every `OPTIONS`
   before it looks at the channel). If the preflight is refused, or it is `204` and a
   second *Use this token* (the JWT is still in the field) fails the same way after
   the two auth fields were compared with `defines.json`: clear the **Auth channel
   id** field, *Use this token* again — the unverified path, the gateway verifies the
   JWT itself — and record `Not run: verify on web — <the preflight status, or the
   sign-in error when the preflight was 204>`. `the token was refused (401)` or an
   `AuthFailure(httpStatus, status 404)` is a finding about the channel, not CORS:
   stop and report it. Then **Enter the lobby**: `lobby connected` with the channel id
   and `tick`, `map loaded`, the chips from the map.
4. **The emulator.** `flutter emulators --launch <avd>`, `adb wait-for-device shell
   'until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done'`, then in
   `examples/playground`:
   `flutter create . --platforms=android` with the same `--project-name` and `--org`
   (the app id is `life.yyt.yyt_playground`), `flutter build apk --debug
   --dart-define-from-file=…`, `adb install -r
   build/app/outputs/flutter-apk/app-debug.apk`, `adb shell am start -n
   life.yyt.yyt_playground/.MainActivity`. Drive it with `adb shell input tap x y`
   after `adb exec-out screencap -p > <scratch>/emu.png` read with the `Read` tool —
   before every tap, since the login screen scrolls when the keyboard opens; dismiss
   the keyboard with its own arrow, because `KEYCODE_BACK` with no keyboard up
   leaves the app. `adb shell input text` mangles a JWT (`/verify` answers `401`):
   the emulator shares the host clipboard, so hold `jwt2.txt` there with `clip.py`,
   long-press the field and tap *Paste* (never screenshot with a paste preview
   open). `verify` runs natively, so the app shows `Signed in as <32 hex>`. Enter
   the lobby, move; Chrome shows `1 peer(s) in view` and the peer moving, and the
   emulator shows Chrome's player.
5. **Background resume, two runs, record both.** The emulator ends the app's
   connections within seconds of HOME (a download body fails) and every handshake
   fails while it is in the background. The lobby screen closes its client on
   `paused` and opens a new one on `resumed` (`flutter.md`), so the app closes the
   lobby socket before the OS can. Each run, followed by a screencap: `adb logcat
   -c`, then `adb shell 'input keyevent KEYCODE_HOME; sleep 8; am start -n
   life.yyt.yyt_playground/.MainActivity'`, then `adb logcat -d -s flutter` (the
   same lines the log panel shows; the banner is what the screencap shows). Walked
   2026-10-01 on `lamp_api36` with this wiring, both runs: `paused: lobby closed`,
   then `resumed: new lobby client` and `lobby connected` within a second of the
   return, the player where it was, no banner, no `refused`; the same with `sleep
   30`. Before the wiring the 30 s run came back `stopped (1006): handshake failed
   5 times in a row` (`maxHandshakeFailures`, 15.5 s ± 20 % of backoff). Record
   what you see, in the `Verified:` line below, verbatim; a divergence is a
   finding, not a mistake in the walk. A real phone may keep the socket longer.
6. **The resumed download over 2 MiB.** Ask a platform admin (the user) for `yyt
   limit set asset.fileBytes 64MiB --bundle <throwaway>-assets --expires 1d --note
   "resume test"` and, since the bundle cap is 20 MiB, `asset.bundleBytes 128MiB`
   the same way; without it, the `Not run:` line. Sync a 40 MiB `huge.bin` into the
   encrypted bundle. The playground's *Download* writes into a counting sink and
   cannot resume, so `flutter create --platforms=android --org life.yyt
   --project-name resumer <scratch>/resumer` with `yingyeothon_asset_client: {path:
   <repo>/packages/yingyeothon_asset_client}` (`<repo>` is this checkout's absolute
   path; same for `_codec` and
   `_logger`) and `path_provider`, and a `main` that on start prints whether
   `huge.bin.part` under `getApplicationSupportDirectory()` exists and its length,
   calls `downloadToFile` with a progress callback that prints the first byte count
   and then one every 4 MiB, and prints `done <bytes>` — counts only, never the URL,
   the path or the key. Build it with the same defines file (read with
   `String.fromEnvironment`), install, start, and once `adb logcat -d -s flutter |
   tail` shows progress: `adb shell am force-stop life.yyt.resumer`, `am start`
   again — logcat prints the part's length `N`, a first progress of `N` plus one
   plaintext segment (65,504 bytes in a keyed bundle), then `done` at the full size.
   Do not slow the emulator's network to make the window (`adb emu network speed …`
   stalls every request until `responseTimeout`); the file size is the window.
7. **Cleanup**, before the emulator closes: `kill` the clipboard holder's and the
   `http.server`'s pids; hold an empty file in `clip.py` for a few seconds so the
   emulator's shared clipboard is overwritten (Gboard may keep a history: the JWT
   dies with the channel below); `adb shell pm clear` and `adb uninstall` both apps;
   `flutter clean` in the example and `rm -rf <scratch>/resumer`; `rm`
   `defines.json`, `key.txt` and the token files; `yyt channels delete` the lobby
   and the auth channel (secrets drop at once), `kv delete` both collections, `asset
   delete` every bundle (a bundle's limit overrides go with it); `adb emu kill`.
   Chrome's cache may hold the built `main.dart.js` until it expires; its key is dead
   with the bundle.

The commit lines:

- `Verified: dev gateway on chrome and <avd>, two clients on one lobby; resume 8 s <what you saw>, 30 s <what you saw>` (2026-10-01: both `reconnected, position kept`)
- `Verified: verify on web (Signed in as 32 hex)` — its own line directly after the
  first, when *Use this token* showed it; otherwise `Not run: verify on web — <the
  preflight status, or the sign-in error when the preflight was 204>` (step 3), and
  covered by `Not run: dev gateway on chrome — …` when Chrome did not run at all.
  The walk of 2026-10-01 (the section's *Walked* note) ran before the auth service's CORS
  deploy later that day and took the unverified path; no run has recorded the
  `Verified:` form yet — edit this sentence away once one does.
- `Verified: dev assets in chrome; resumed download on <avd> (40 MiB, killed and resumed)`
- `Not run: dev gateway on chrome — no extension` (also when the extension has no permission for the site)
- `Not run: dev gateway on android — no emulator`
- `Not run: dev gateway on chrome and android — no tkinter for the clipboard`
- `Not run: dev assets, resumed download — no admin for the limit`

## Method

- Vary one thing at a time. A claim that a change restored a behaviour needs a
  negative control: the same steps on the previous commit.
- Record each run in the commit message body, one line: `Verified: offline demo on
  linux, walked <steps>` (or `Verified: dev gateway, …`, `Verified: dev kv,
  round_trip_test`). There are no PRs to carry
  it and no docs page owns it.
