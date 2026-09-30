# Flutter

The libraries are engine-free; this file is about the app around them.

## Boundaries

- Nothing under `packages/` imports `package:flutter`. Lifecycle, widgets,
  `debugPrint`, `url_launcher`, deep links, secure storage: all app code, and the
  example shows the wiring. A Flutter-only convenience goes in the example, not in a
  package.
- The example stays **outside** the pub workspace and depends on the packages by
  `path:`. Putting it in would make `dart pub get` and `dart test` at the root need
  the Flutter SDK (`tooling.md`).

## Platforms

- Web has no `dart:io` and no custom headers on a browser WebSocket. The token rides
  the subprotocol list on every platform for that reason; `package:web_socket_channel`
  is the one transport, and the code has no `dart:io` import under `lib/` except in
  `fake_gateway`, which is never shipped, and in
  `asset_client/lib/yingyeothon_asset_client_io.dart` (`downloadToFile`).
- A `dart:io` convenience goes in a library of its own that the core barrel never
  imports, as `yingyeothon_asset_client_io.dart` does — never in a `part` of the core
  or a file the core imports: a part shares its library's imports, and the core would
  stop compiling for web. Prove the split with `(cd packages/yingyeothon_asset_client
  && dart test -p chrome test/asset_client_test.dart)`, the one suite there that
  imports only the core barrel; the gate does not run it, and without Chrome say so
  in the commit's `Verified:` line.
- On web a browser reports every failed handshake as close `1006`. The policy is
  written for that: `maxHandshakeFailures` is what ends a dead token, not a status
  code.
- iOS suspends sockets when the app pauses; Android may. Expect a close on resume and
  let the reconnect policy run. If you wire `WidgetsBindingObserver`, do it in the app:
  `close()` on `paused` if you want a clean end, or nothing and let `4002` reconnect.
- `dart:io`'s `WebSocket.done` on a **server** socket does not complete after a
  client-initiated close; the stream's end does. The fake gateway and the transport
  tests read the stream for that reason.

## Threads and frames

- Dart is single-threaded; there is no `Poll()` and no pump. Every SDK event lands on
  the event loop from a socket event or a timer, synchronously through a broadcast
  stream. A listener that calls `setState` must check `mounted`; a `State` that holds a
  client cancels its subscriptions and `close()`s it in `dispose()`.
- A `pos` batch arrives once per `hello.tick`; render from the peer map, not from every
  frame.

## Debug affordances

- Every debug affordance is gated by `kDebugMode` and lives in `examples/playground/
  lib/debug/`: the offline demo (in-process fake gateway), peer seeding, a forced close
  code, a `q` abort. `flutter test` runs in debug mode, so widget tests reach them; a
  `--release` build cannot.
- The offline demo is the default manual-verification target because it needs no
  credential and no network (`manual-verification.md`).

## Example mechanics

- Platform folders are not committed. `flutter create . --platforms=linux
  --project-name yyt_playground --org life.yyt` injects them and never overwrites
  `lib/`, `test/`, `pubspec.yaml`, `README.md` or `analysis_options.yaml`. It *does*
  create `test/widget_test.dart` when absent (the counter test, which fails here), so
  a real test keeps that name. `--platforms=web` does touch one tracked file: it adds
  `web/**` to the analyzer excludes in `analysis_options.yaml` (checked 2026-09-29,
  Flutter 3.47), so that line is committed — without it CI's clean-tree check after
  the web `create` fails. A new platform gets the same check: run its `create`,
  then `git status --porcelain .`.
- Desktop input facts (checked 2026-10-01, Flutter 3.47.5, against the SDK's
  `material/drawer.dart` and `material/app_bar.dart`): a drawer never opens from an
  edge drag on linux, macOS or windows, and an `AppBar` adds its automatic drawer
  button only when `actions` is empty, so a drawer behind an app bar with actions
  needs its own button (the lobby's debug drawer has one). A `TabBarView` does not
  swipe with a mouse; click the tab.
- Configuration is `--dart-define=YYT_*` first, then the login screen (memory only,
  never persisted). Nothing in the example stores a token.
- Numbers on the wire are `double`; pass `x.toDouble()` from an `int` slider.
- **A screen's `dispose` does not notify the session.** The tree is locked during
  `dispose`, and the screen below it still listens to `Session`, so a
  `notifyListeners()` there is "setState() or markNeedsBuild() called when widget
  tree was locked" on every Back — the key-value screen shipped with it and no test
  popped. Close with `notify: false` (`closeKv`, `closeAssets`), and give each new
  screen a `tester.pageBack()` test that expects no exception.
