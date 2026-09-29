# Testing

## Principles

- No development task is complete without tests covering the new or changed
  behaviour. Rule and prose changes have no behaviour; say so.
- Keep logic free of sockets, clocks, `dart:io` and Flutter so it runs under
  `dart test` with no network. The seams in `architecture.md` exist for this.
- Each package is covered by **its own** suite: `check_coverage` runs `dart test` per
  package with `-x integration` and keeps only that package's `lib/` lines — line
  ≥ 80 %, branch ≥ 70 %. A sibling's suite walking through your code does not count.
- Test files live in `packages/<name>/test/`, import only the public barrel, and share
  doubles from `packages/yingyeothon_gamebase_client/test/support/` (the other
  packages keep theirs in their own `test/`, inline or in one support file such as
  `kvstore_client/test/fake_http_client.dart`). If a test needs something internal,
  that thing should be public or the test is testing the wrong layer.

## Doubles

- `FakeWebSocket` / `FakeWebSocketFactory` (`gamebase_client/test/support/`): the test
  is the server — `serverOpen`, `serverSend`, `serverSendRaw`, `serverSendBinary`,
  `serverClose`, `serverError`. Delivery is synchronous with a re-entrancy queue, so a
  test asserts right after the call and never flushes microtasks for a socket event.
  `deferClose` reproduces a real transport that reports a close only after the
  handshake finishes — the "late hello" cases need it.
- Time: `fakeAsync` + `elapse`. Pin a schedule from both sides (`elapse(499)` shows no
  socket, `elapse(1)` shows one). Never `Future.delayed` in a unit test.
- Random: `BackoffOptions(random: () => 0.5)`; test the jitter edges with `0` and
  `0.999999`.
- HTTP: a scripted `MapHttpFetcher` or an `http.BaseClient` subclass with an answer
  queue (`auth_client/test/`, `kvstore_client/test/fake_http_client.dart`, which
  also stalls headers or a body to drive the timeout). Never a real host.
  `asset_client/test/support/fake_cdn.dart` is a CDN: objects by URL, `Range`,
  `If-Range` and `HEAD` answered as CloudFront does, a `crossOrigin` mode that hides
  every header a browser cannot read, and `openBodies`, which a test that reads or
  abandons a body asserts is 0 at its end — a body the client neither read to the
  end nor cancelled holds a connection.
- Crypto: the service's `docs/asset-encryption-vectors.json` is `asset_client`'s
  conformance test, run through the public client in both request modes (whole, and
  by every range across a segment boundary; every negative case `asset_corrupt`).
  The test encryptor in `test/support/encrypt.dart` shares nothing with the library
  above the AES block cipher (HMAC and HKDF from `package:crypto`, CTR from
  pointycastle's `SICStreamCipher`, where the library runs its own CTR over
  `AESEngine` and pointycastle's `HMac`), so the two can disagree. When the service
  regenerates the vectors, copy the file again, name the service commit in
  `vectors_test.dart`, and update the case counts in its first test.
- `flutter_test` replaces every `HttpClient` with one that answers an empty `400`;
  a widget test that talks HTTP to the fake gateway sets `HttpOverrides.global =
  null` (each test file is its own isolate). In a file whose other tests rely on
  the stub `400` — a failed map fetch leaves no timer — set it in the one test that
  needs real HTTP and restore it with `addTearDown`, as `lobby_screen_test.dart`
  does. WebSocket tests are not affected. If such a test then fails with a pending
  timer, that is the pooled connection's 15 s idle timer: end the test with
  `tester.pump(const Duration(seconds: 16))`.
- Inside a `testWidgets` body, real I/O — starting or shutting down a
  `FakeGateway`, a raw `WebSocket` — is awaited inside `tester.runAsync`; awaited
  on the test clock it never completes and the run just hangs, naming no test.
  `setUp` and `tearDown` run on real time and need no wrapper. Bisect a hang with
  `timeout 90 flutter test <file> --plain-name '<name>'`.
- Logging: `CapturingLogWriter` (`gamebase_client/test/support/harness.dart`; the
  logger suite has its own copy) records `LogWriters.format` output, so a test
  asserts whole lines.
- `LobbyHarness` / `GameHarness` build a client over the fakes, record every event as a
  string in `trace`, and hold the `connect()` future so a failure is observed rather
  than unhandled. `connectError` needs `async.flushMicrotasks()` after the event that
  fails it: the completer's continuation is a microtask.

## What a test must do

- **Assert the order as one list.** `expect(h.trace, ['connected:me',
  'disconnected:4002:true', 'reconnecting:1:500', ...])`, not counts.
- **Pin wire bytes.** A sender test compares `sentRaw` to the exact JSON string; a
  round-trip proves nothing about what the gateway sees.
- **A timer an operation arms is cancelled when the operation settles.** A
  `Future.delayed` raced with `Future.any` never is; use `.timeout(...)`
  (`architecture.md`) or a `Timer` + `Completer` cancelled in `finally`, and pin it
  with `fakeAsync`: `expect(async.pendingTimers, isEmpty)` after a success *and*
  after a failure. The map fetcher's 30 s deadline once outlived every fetch.
- **A negative assertion needs a positive control.** "The token is not in the log" is
  meaningless if the log is empty: assert the expected line exists first. The codec
  keeps a test that `dart:convert` *does* quote the input, so the wrapper's reason for
  existing is checked too.
- **Both sides of every boundary.** 16 bytes of `dir` pass and 17 refuse; 64 KiB passes
  and 64 KiB + 1 closes; `maxLength` decodes and `maxLength + 1` is refused.
- **Failing grammar as densely as succeeding.** Every refusal code, every close code,
  every `omitempty` shape.
- A message-does-not-quote-input test asserts **equality with a template** computed
  from the code and offset, not just absence of one string.

## Integration tests

- `@Tags(['integration'])` marks tests that open a loopback socket: the real
  `WebSocketChannelFactory` against a scripted `dart:io` server, and the SDK against
  `yingyeothon_fake_gateway`. The per-member `dart test` in the gate runs them;
  `check_coverage` excludes them.
- A `dart:io` server socket answers a close frame only while its stream is read, and
  its `done` never completes after a client-initiated close. Read the stream to its end
  and take `closeCode` there (`ScriptedServer.closedCode`).
- Give every await in an integration test a timeout (`soon()`), so a hang is a
  failure with a name rather than a 30-second silence.
- The fake gateway flushes `pos` batches on its own timer, so `RawClient.next()` in
  its suite skips them; assert a batch with `nextPosOf(userId)`, and give a test
  about flush timing a slow `tick` plus a `ping`/`pong` drain before the step it
  measures. Its failure modes are off unless a test asks: options (`channels`,
  `games`, `acceptedTokens`, `maxMoveDelta`) or calls (`refuseHandshakes`,
  `stallGame`, `holdOutbound`). Keep a new one off by default, so the other suites
  do not change, and list it in the fake README's paragraph that begins "It also
  reproduces the failures".
- The fake gateway's tests drive it with raw `dart:io` sockets, and its `/kv/*` routes
  with a raw `HttpClient`, so the fake is tested against the protocol, not against
  the SDK it exists to test.
- The store's integration test walks the guide's two cases against the fake, and,
  when `YYT_KV_BASE_URL` and `YYT_KV_TOKEN` are set, against dev; without them it is
  skipped, never failed. Neither value is printed.

## Gate scripts are code

- `tool/test/check_docs_test.dart` builds a green fixture repository and breaks one
  thing per test, expecting exactly that failure. A check that silently stops firing
  fails there. Add a test when you add a check.
- The example's widget tests run under `flutter test` with the fake gateway in
  process; they are the example's coverage, not a package's.
