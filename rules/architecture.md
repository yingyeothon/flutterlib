# Architecture

`CONVENTIONS.md` owns the API shape. This file holds what the port taught.

## The port

- Three originals, one spec. tslib's `gamebase-client` is the behavioural reference
  (Dart shares its event-loop model), csharplib's is where the defects were found and
  fixed (retired sockets, emit-before-settle, `dir` clearing, byte caps), and the
  gateway README plus `protocol.go` in the `service` repo are the wire truth. When they
  disagree, the gateway wins; when tslib and csharplib disagree, csharplib is the
  later fix.
- Two things the originals do not model are in Dart from the start: `hello.aoi`
  (`maxPeers`, optional `range`) and close `4005` (too slow → reconnect). Add a new
  gateway field or code here first, then the tests, then the docs.
- Only what runs on a phone is ported. The rest of tslib is server code; the root
  README says which and why. Adding one needs a reason that survives "can this run on
  a phone?".

## The state machine (`gamebase_client/lib/src/internal/gateway_socket.dart`)

- One state machine, two protocols: `lobby` completes `connect()` on `hello`, `q` on
  open. Everything else (bearer echo, hello timeout, close-code policy, backoff,
  handshake-failure count) is shared. Do not fork it per client.
- **Retired socket.** A local close (`hello timeout`, wrong subprotocol, oversized
  frame) marks the socket retired; nothing it says afterwards counts except its close.
  `web_socket_channel` keeps delivering queued messages after `sink.close()`, and a
  `hello` that slips through would resurrect a connection the policy already ended.
- **Identity, not state.** Every socket event is checked against the *current* socket
  by identity first. A closed socket from an earlier attempt can still report.
- **Deliver, then announce, then settle.** `_markReady(deliver)` runs the `hello` /
  `opened` emit first, then emits `stateChanges(connected)`, then completes the pending
  `connect()`. A state listener therefore reads a populated client, and
  `await connect()` resumes (as a microtask) after both. The first version announced
  the state before `hello` was applied; a `stateChanges` listener saw `hello == null`.
- The hello timer is created before the `opened` emit, so a `close()` from an
  `opened` handler cancels it instead of leaving a 10 s timer pending.
- **`close()` inside a handler.** A `disconnected` handler may call `close()`; the
  reconnect scheduler checks `_closedByUser` again after emitting and returns. Do not
  hoist that check.
- **Emitter re-entrancy.** `StreamController.broadcast(sync: true)` throws on a nested
  `add`. `Emitter` queues a nested emit and drains it after the current one, which is
  what keeps a frame sent from a handler (and answered synchronously by a fake) in
  order. Every event stream in the SDK goes through it.
- What the state machine may log is listed once, in `security.md` (*The token*);
  add a field there before adding it to a log line.

## Wire shapes

- The gateway marshals with Go `omitempty`: `leaderId`, `invited`, `max` and `to`
  vanish when empty, `partyId: ""` means no party, and a nil slice is JSON `null`.
  `readLobbyFrame` fills the roster in and `Normalize.optionalId` folds `""`/absent to
  `null` so a handler never checks both.
- `capabilities.say`: absent means the gateway did not say (unrestricted); present
  and `null` is an empty Go slice, which the gateway's `AllowsSay` refuses for every
  scope, so it reads as `[]`. `event` is gated by the `event` flag only — the say list
  never applies to it (tslib's mistake, csharplib's fix).
- A `pos` entry without `dir` clears the peer's facing. tslib kept the old one; that
  is the bug csharplib fixed.
- `q` frames are any JSON value (`Stream<Object?>`), not only objects; a gateway `error`
  is split off by `type == "error"` with a string `code`.
- Inbound caps are bytes: 64 KiB per text frame in the transport (the gateway's
  outbound cap is 32 KiB), 16 bytes for `dir`, 16 MiB for a map body on the wire
  (`HttpMapFetcher.maxBytes`) and 64 MiB of characters for its JSON
  (`Json.maxBigLength`). The
  transport measures UTF-8 only past `length > cap / 3`, which is the cheapest exact
  bound. An oversized inbound frame is a local `4900` close that reconnects; `1009` is
  reserved for what the gateway says about a frame *you* sent.
- A `q` frame needs a string `type`; the gateway refuses anything else as
  `bad_message`, and the client refuses it locally for the same reason it refuses
  `enter`/`leave`. A gateway `error` on `q` is one with a string `code` **and** a
  string `message`; anything else is the game's own frame.
- A `pos` or `leave` for a peer not in view breaks the gateway's view invariant: the
  frame is ignored for rendering and logged at `debug` (type only). An `enter`
  without a `userId` is a protocol error, not a peer named `""`.

## Seams

- Transport: `GatewayWebSocketFactory` / `GatewayWebSocket` (`Stream<SocketEvent>`). The
  default is `WebSocketChannelFactory`; a test injects `FakeWebSocket`; the offline demo
  injects nothing and points at the fake gateway's URL. A transport connects in its
  constructor and buffers events until listened to — a subscriber that arrives late
  must not deadlock a handshake that never started.
- HTTP: `MapHttpFetcher` for the map, `http.Client` for auth. Both default to
  `package:http` with a timeout, a size cap and a redirect budget.
- Time: `Timer` and `package:fake_async` in tests. No clock abstraction; Dart's is
  enough.
- Random: `BackoffOptions.random`, defaulting to a fresh `Random()` per backoff so two
  clients do not reconnect in lock-step.

## Dependencies

- Sibling dependencies are relative `path:` entries (`yingyeothon_codec: path:
  ../yingyeothon_codec`). The workspace resolves them to source, and — the reason
  they are paths — a consumer installing by git dependency resolves them inside the
  same checkout. A version constraint would send that consumer to pub.dev, where
  nothing is published; a scratch app against a local clone proved it. Every
  package is `publish_to: none` for the same reason.

## Codec

- `dart:convert` parses; `yingyeothon_codec` bounds it: length before parsing, depth
  after (iterative walk), a non-throwing `tryDecode`, and a failure that is a code and
  an offset. `FormatException.toString()` quotes the input, so it never crosses the
  package boundary.
- The workspace resolves sibling packages to source, so `dart test --coverage-path`
  in one package reports lines of its siblings too. `check_coverage` keeps only the
  package's own `lib/`.
