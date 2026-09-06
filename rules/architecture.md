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

## The key-value client (`kvstore_client`)

- One request choke point (`internal/requester.dart`): the token is used in exactly
  one place, every URL is built by `KvPaths.resolve` from checked segments, and one
  `debug` line per request carries the method, the route *kind*, the status and the
  body length — never the collection, the owner or the key.
- **Absent is `orElse`.** A stored JSON `null` decodes to Dart `null`, so `get()`
  cannot return `null` for a missing key: `getEntry()` is the null-returning tier
  and `get(key, orElse:)` the value tier. Do not "simplify" `get()` to return `null`
  on 404; the offline demo's "no settings yet" case is exactly the one it breaks.
- A 404 is one answer for "no such key" and "no such collection in this project";
  the client cannot tell them apart without reading the message, and messages are
  not a contract. `delete()` folds it too: a reader's delete of a missing key is a
  `404` on the server (`deleteEntry` reports `missing` before it compares the
  version), a write-only caller's is `204`, and neither is an error to the caller.
- The server's own README and a todo's "facts" list are summaries; the route source
  (`services/state/src/kvstore.ts`) is what the fake and the client follow. Two of
  the todo's facts were wrong against it (delete is not "204 always"; a deleted row
  is removed and a reborn key restarts at version 1, only an *expired* row keeps its
  version). Check each fact against the source before pinning it in a test.
- One `.timeout` around the whole exchange (headers and body together): a per-chunk
  `stream.timeout` lets a drip-fed body run until the byte cap. A token is checked
  for printable ASCII at construction because `dart:io` refuses any other header
  value with a `FormatException` that quotes the whole `Bearer …` line; the last
  `on Exception` in the requester exists for the same family of messages.
- A server-chosen `code` or `reason` is kept only when it matches
  `^[a-z][a-z0-9_]{0,63}$`; it reaches `toString()` and log lines, and an `http://`
  base URL means whatever answered chose it.
- Grammar is checked locally only where the server checks it (`KvRules`, cited to
  `service/packages/console-db/src/kvstore.ts`); the owner grammar is checked too
  because an owner goes on the path unencoded. The `me` alias passes as itself.
- `http.Request.body` appends a charset to a content type set *before* it; set the
  body first and the header after, or the header a test pins changes.
- A write-only caller sees `204` and no `ETag` on every write; `created` and
  `version` are null then (`expiresAt` still arrives when that write set a `ttl`),
  and `created` is derived from the status only when a version came back.

## Seams

- Transport: `GatewayWebSocketFactory` / `GatewayWebSocket` (`Stream<SocketEvent>`). The
  default is `WebSocketChannelFactory`; a test injects `FakeWebSocket`; the offline demo
  injects nothing and points at the fake gateway's URL. A transport connects in its
  constructor and buffers events until listened to — a subscriber that arrives late
  must not deadlock a handshake that never started.
- HTTP: `MapHttpFetcher` for the map, `http.Client` for auth and the key-value
  store. All default to `package:http` with a timeout and a size cap (the map
  fetcher adds a redirect budget); the store's cap is 4 MiB, a full page of values.
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
