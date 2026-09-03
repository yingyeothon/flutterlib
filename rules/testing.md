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
  doubles from `test/support/`. If a test needs something internal, that thing should
  be public or the test is testing the wrong layer.

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
  queue. Never a real host.
- Logging: `CapturingLogWriter` records `LogWriters.format` output, so a test asserts
  whole lines.
- `LobbyHarness` / `GameHarness` build a client over the fakes, record every event as a
  string in `trace`, and hold the `connect()` future so a failure is observed rather
  than unhandled. `connectError` needs `async.flushMicrotasks()` after the event that
  fails it: the completer's continuation is a microtask.

## What a test must do

- **Assert the order as one list.** `expect(h.trace, ['connected:me',
  'disconnected:4002:true', 'reconnecting:1:500', ...])`, not counts.
- **Pin wire bytes.** A sender test compares `sentRaw` to the exact JSON string; a
  round-trip proves nothing about what the gateway sees.
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
- The fake gateway's tests drive it with raw `dart:io` sockets, so the fake is tested
  against the protocol, not against the SDK it exists to test.

## Gate scripts are code

- `tool/test/check_docs_test.dart` builds a green fixture repository and breaks one
  thing per test, expecting exactly that failure. A check that silently stops firing
  fails there. Add a test when you add a check.
- The example's widget tests run under `flutter test` with the fake gateway in
  process; they are the example's coverage, not a package's.
