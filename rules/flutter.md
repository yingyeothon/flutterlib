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
  `fake_gateway`, which is never shipped.
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
  a real test keeps that name.
- Configuration is `--dart-define=YYT_*` first, then the login screen (memory only,
  never persisted). Nothing in the example stores a token.
- Numbers on the wire are `double`; pass `x.toDouble()` from an `int` slider.
