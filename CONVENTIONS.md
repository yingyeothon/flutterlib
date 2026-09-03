# Conventions

API design rules for every `packages/yingyeothon_*` package. Canonical: a rule file may
point here, never restate or contradict.

## Shape

- **Pure Dart.** Nothing under `packages/` imports `package:flutter`. Platform glue
  (lifecycle, widgets, `debugPrint`, deep links, secure storage) belongs to the app.
- **Interfaces with factory constructors.** A public type a consumer holds is an
  `abstract interface class` with a `factory` that redirects to an implementation in
  `lib/src/internal/` (`GatewayLobbyClient(options)`). The implementation is never
  exported; a test that needs it is a test of something that should be public.
- **Immutable options.** Options are `final class`es with `const` constructors and named
  parameters; a client copies what it needs at construction. A new token means a new
  client.
- **Streams for events, methods for commands.** Every event is a `Stream<T>` getter
  backed by a synchronous broadcast emitter; the receiver-side names are past tense or
  descriptive (`said`, `eventReceived`, `partyChanged`, `refused`) so they never collide
  with the sender (`say()`, `event()`, `party`, `send()`).
- **Explicit exports.** The barrel `lib/<name>.dart` exports with `show` lists only.
  `check_docs` reads them and matches them against `## Public API`.
- **Sealed wire types.** A frame family is a `sealed class` with one `final class` per
  wire `type`, an `Unknown…` member for anything else, and a `raw` map on every
  member. Open string sets (error codes) are `abstract final class` constants, not
  enums, so a new code cannot become a parse failure.
- **Absent is not null.** A wire field the peer omitted reads as `null` in Dart; a
  builder omits a `null` and writes `null` only through `setNull`. `Normalize.optionalId`
  folds `""` and absent into `null` where the gateway means the same thing.

## Failure

- **Refuse locally only what the gateway would refuse.** A local check gives a fast
  `StateError`/`ArgumentError`; the gateway is the enforcement. Never be stricter than
  the gateway.
- **A message never carries the input.** A parse failure is a code and an offset; a
  transport refusal names an index, not a character; an HTTP failure is a status. Test
  it by asserting equality with a template nothing from the input can satisfy.
- **`connect()` fails with `GatewayStoppedException`**, never hangs; every other
  failure after connect is an event, not an exception.

## Numbers and bytes

- Positions are `double` (the wire is Go `float64`). Every size cap is measured in
  UTF-8 **bytes**, never `String.length`.
- Constants the gateway documents (`4000`–`4005`, 16-byte `dir`, 500 ms backoff) live in
  one named place each and are cited from the gateway README, not tuned here.

## Logging

- Every package takes a `Logger` option and defaults to `nullLogger`. A log line carries
  ids, codes, counts and lengths — never a token, a frame body, a payload, a close
  reason's text, an exception message built from input, or a URL that came off the
  wire.

## Documentation

- Every public symbol has a `///` comment that says what a consumer needs and nothing a
  reader of the source does not. The package README's `## Public API` names every
  exported symbol; `docs/` explains the flow; `rules/documentation.md` owns the split.
