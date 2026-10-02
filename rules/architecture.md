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
- A `pos` entry or a `leave` for a peer not in view breaks the gateway's view
  invariant (`docs/lobby.md` says what the consumer sees). The lobby client checks
  for one **before** `PeerMap.apply`, never on its `null`: one batch can move a
  known peer beside a ghost, and its known entries still apply. The check visits
  every entry (a short-circuit stops recording), and the `debug` line — the type
  and the channel, never the peer's id — fires once per peer: the noted ids stay
  in memory, cleared with the map on `disconnected` and on every snapshot, and
  dropped when the peer really enters. Before the first snapshot anyone but you
  is a ghost. An `enter` without a `userId` is a protocol error, not a peer named
  `""`.

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
  version). Check each fact against the source before pinning it in a test. The one
  sanctioned exception is where the code contradicts its own comment and the
  service's docs: the fake then follows the comment and lists the deviation in its
  README (_Differences_). When the service fixes either side, follow the code and
  drop the README entry.
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
- **The client and the fake follow the service's kv source, not a date.** The last
  port is service `d3fac64` (2026-09-09: the `server` scope, mail and its stamp,
  `incr` bounds, `GET /time`); it went unported for three weeks, and meanwhile
  `isUserNamespace` read `writeScope` alone while the service's `isKvPerOwner` takes
  either scope, so a mail collection got the wrong path. Every later commit up to
  `a3fa068` was read on 2026-09-30 and changes no kv route (console caps, and the
  `/lb` and `/social` stacks, which have clients of their own since 2026-10-01).
  Before kv work, fetch the `service` repository and
  run, as one line:

  ```bash
  git -C ~/git/yyt.life/service log --oneline a3fa068..origin/main -- services/state/src services/state/README.md packages/console-db/src/kvstore.ts docs/kvstore.md
  ```

  Read every commit it lists, port what a client can see into both the client and
  the fake, then replace `a3fa068` in this bullet (both places) with the newest
  commit you read, and `d3fac64` with the newest commit you ported, if any. An empty
  list changes nothing here.
- The meta route is the current instance of the exception above (reported to the
  owner 2026-09-30); `yingyeothon_fake_gateway/README.md` owns the details.
- One requester type, `KvRequester`. The token is pinned once, in its constructor;
  `send(authorized:)` is the per-call switch, and on an authorized send the
  `authorization` header is set after the caller's headers so no caller can
  replace it. `GET /time` is the one route sent with `authorized: false` (this
  sentence is the only count; the code comments do not repeat it). A
  `KvRequester(token: null)` is the tokenless configuration: an authorized `send`
  through it is a `StateError`, thrown before the exchange, a guard no public path
  reaches today. A new unauthenticated route gets a `KvRoute` member and an
  instance method with the flag; a static twin (today only `fetchServerTime`)
  only when a caller needs it before any token exists. The twin and the factory
  both check their options **before** creating a client (named arguments are
  evaluated in source order, so the checks come first in the argument list),
  which is what makes a refusal synchronous and leak-free; the twin passes
  `token: null`, takes the factory's defaults, owns its client only when none was
  passed, and closes what it owns when the request settles.

## The leaderboard client (`leaderboard_client`)

- The same host, token and shape as the key-value client: one requester
  (`internal/requester.dart`), one `debug` line per request (method, route *kind*,
  status, bytes — never the board, the owner, a score or a `meta`), grammars in
  `LbRules` cited to `packages/console-db/src/leaderboard.ts` (the owner grammar
  from `kvstore.ts`, as the service's `checkOwnerId` is kv's), and an exception
  that is a status, a code and a `details.reason` word. A change to one requester
  is a change to all three (kv, leaderboard, social): before editing one, `diff`
  the `lib/src/internal/requester.dart` files (they differ in names and route
  enums, in the kv-only answer headers and `headers:` parameter, and in kv's
  4 MiB cap against the others' 1 MiB) and make the same change to the exchange,
  the exception mapping and the log line in the other two.
- **A client never names a bucket key.** The API takes a period *name*, the
  platform computes the key in `Asia/Seoul` and every answer carries `periodKey`
  and `periodEndsAt` (`null` for alltime, so the field is nullable); the fake
  computes them the same way (`periodKey` on `FakeLeaderboardStore`, pinned in its
  test at the two ISO-week boundaries the service pins in
  `packages/console-db/test/leaderboard.test.ts`: `2027-01-01` → `2026-W53` and
  `2024-12-30` → `2025-W01`).
- `meta` is text: sent as a JSON string, never an object, so an integer past 2^53
  round-trips; the client refuses a control character and more than 1 KiB locally
  because the service does, and nothing else about it.
- The board is resolved before the credential *rule*: a player on a `submit:
  server` board that does not exist is a `404`, not a `403`, so an id is never an
  oracle. Identity itself (`401`) comes first in both.
- Read up to service `fcb8f49` (2026-10-01; a rules commit touching no lb path,
  so it is the read watermark, and the port is of the routes as they stood).
  Before leaderboard work, fetch the `service` repository and run, as one line:

  ```bash
  git -C ~/git/yyt.life/service log --oneline fcb8f49..origin/main -- services/state/src/leaderboard.ts services/state/README.md packages/console-db/src/leaderboard.ts docs/leaderboard.md
  ```

  Read every commit it lists, port what a client can see into the client and the
  fake, then replace `fcb8f49` in this bullet (both places) with the newest commit
  you read. An empty list changes nothing here.

## The social client (`social_client`)

- The third client on the state host, the same shape again (one requester, the
  `debug` line with method, route *kind*, status and bytes — never a player id, a
  display name or an avatar; grammars in `SocialRules` cited to
  `packages/console-db/src/social.ts`, the profile owner grammar from `kvstore.ts`).
  The requester rule of the leaderboard section applies to all three files.
- **A relation's other end is always a player (32 hex); a card's owner may be a
  guild (`kind:id`).** `SocialPaths` checks the two grammars apart, so
  `server.friendsOf('guild:red')` is a local refusal while `server.putProfile` of
  it is not. A `me` route from a server key and a server route from a player are
  the service's `403`; the client does not pre-empt them.
- **The display name is the player's text.** The client refuses what the server
  refuses (`\p{Cc}`, `\p{Cf}`, U+2028/2029, a run of five or more `\p{Mn}`)
  and nothing more; what comes back off the wire is another player's text and
  must pass the app's own label check before it is shown, with the owner id
  standing in otherwise — the playground's Friends screen does so with
  `MapLayout.isLabel`, and its test seeds a name past the write filter to prove
  it (`security.md`, "Trusting the wire").
- The fake follows the transition planners in `console-db/src/social.ts`: the
  shared `404` (no card, blocked you, no such
  player), a decline kept as a `dropped` row the sender sees as pending, a block
  that drops the peer's request or friendship but never their block, an unblock
  that restores a kept cooldown, mutual requests settling at once with both
  friend caps, a card delete that spares others' blocks. Its identities are token
  texts, so the 32-hex rule on a token's subject is not enforced there; a test
  that sends an id through the client uses a 32-hex one. Where it departs
  (identity before routing, one owner grammar for every path, a row's `since`
  moving on every write, no expiry) the fake README's _Differences_ says so.
- Read up to service `fcb8f49` (read 2026-10-01; the commit is of 2026-09-29 and
  touches no social path, so it is the read watermark). Before social work, fetch the
  `service` repository and run, as one line:

  ```bash
  git -C ~/git/yyt.life/service log --oneline fcb8f49..origin/main -- services/state/src/social.ts services/state/README.md packages/console-db/src/social.ts docs/social.md
  ```

  Read every commit it lists, port what a client can see into the client and the
  fake, then replace `fcb8f49` in this bullet (both places) with the newest commit
  you read. An empty list changes nothing here.

## The asset client (`asset_client`)

Files: `lib/src/internal/client_impl.dart` (`download`, `_OuterSink`, `_restarting`),
`lib/src/internal/http.dart` (`CancelSignal`, `_orCancelled`, `Requester.send`,
`BodyReader`), `lib/yingyeothon_asset_client_io.dart` (`downloadToFile`,
`_CallerError`, `_promote`).

- **The cancel signal rides a zone, and the caller's callbacks must not.**
  `download(cancel:)` runs under `runZoned` with the `CancelSignal` under
  `cancelKey`, so every request and body read below finds it (`currentCancel()`).
  The two callbacks the caller passes per call — the sink and `onProgress` — are
  therefore called in the caller's zone (`_OuterSink`, `outer.runUnary`). Tests:
  `asset_client_test.dart`, "a read the sink starts does not inherit the cancel"
  and "a read onProgress starts does not inherit the cancel". A download without
  `cancel` also runs under `cancelKey: null`: no public path reaches it while the
  wrapping holds, so no test pins it — it is the second fence for a callback added
  later without the wrapping, and stays. What the caller gives
  once, in the options (the `http.Client`, the logger), is not a per-call callback
  and stays where it is.
- Each wait on the network registers on the signal with `CancelSignal.listen` and
  calls the remover when it no longer needs it: `_orCancelled` when its future
  settles, and `Requester.send`'s abort listener when the body is done
  (`BodyReader._finish`) — **not** when the headers arrive, since aborting the
  request is what frees the connection of a body that stalled. A listener added
  per chunk and never removed accumulates on a future the app may keep for a
  screen's lifetime. Known gap: the removal is untested, because a test would need
  the internal `CancelSignal` and tests import no `src/internal` (CONVENTIONS.md,
  *Interfaces with factory constructors*); keep the remover calls when refactoring.
- `_restarting` checks the signal before `onChanged` resets the sink, so a cancelled
  download never wipes what the sink holds; keep the check before the reset.
- A `cancel` future is watched — `CancelSignal(cancel)` constructed, which attaches
  its error handler — before any argument check, in `download` and in
  `downloadToFile`; otherwise one the caller later completes with an error is an
  uncaught error (tests: "a cancel that fails after a refused path…" in
  `asset_client_test.dart`, "…after a refused argument…" in
  `io_verified_download_test.dart`).
- `downloadToFile`'s private `_download` decides by exception type in the `try`
  around `transfer()` (a `FileSystemException` is a local failure, `size_mismatch`
  deletes the part). A caller's code must never be classified as one of those:
  `onProgress` throws cross wrapped in `_CallerError` and are unwrapped in
  `downloadToFile`, and `validate` runs in `_promote`, after that `try` (tests in
  `io_verified_download_test.dart`: "what onProgress throws is the caller's…", "a
  FileSystemException from validate keeps the part…"). The
  `_FileSink` is the function's own, not the caller's: its `size_mismatch` must
  stay classified.

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
