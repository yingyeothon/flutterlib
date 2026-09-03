# Security

## Public repository

- This repo is **public** on GitHub and stays public. Treat every commit as
  world-readable, including commit messages.
- It has no infrastructure and needs no credentials, which makes the rule simple:
  **nothing of a credential's shape belongs here at all.** No `local/`, no `.env`, no
  keystore, no provisioning profile, no `google-services.json` — a file of that shape
  is a mistake, not configuration.
- Hostnames are allowed only where the sibling **public** `service` repo already
  publishes them (`gw`, `auth`, `console`, `d` and their `-dev` twins under
  `yyt.life`). Repeating what is already public is not a disclosure; being the first to
  publish something is. Check `git grep` in `service` before adding a new one, and
  never add a stateful host, database or account name — those live in the private ops
  repo.
- **The dev-only token-minting endpoint and its header stay out of this repository
  entirely — code, docs, rules and commit messages.** `tool/forbidden-terms.txt` refuses
  them; the recipe belongs to the `service` repo's smoke scripts.
- The platform design notes in the parent directory, and the `service` repo's private
  planning and local directories, are private. Nothing from them belongs here, however
  useful.
- The one credential-shaped literal in the tree is the test fixture
  `eyJ.secret-token.sig`: three dot-separated words that look like a JWT and are not
  one. The "never logs the token" tests need a literal to search for. Keep it obviously
  fake and keep the `.gitleaks.toml` allowlist entry pointed at that exact string, not
  at the files that hold it. A JWT-shaped fixture with a real base64 payload is built
  at runtime in the test, never written as a literal — gitleaks refused one.
- **Defenses, all required, none optional:**
  - `.gitignore` — tool output, platform folders, every credential-shaped path.
  - `tool/git-hooks/pre-commit` — refuses those paths even when force-added, refuses
    added lines that match `tool/forbidden-terms.txt` (and `local/identifiers.txt`
    when present), then `gitleaks protect --staged`.
  - `tool/git-hooks/pre-push` — scans the **entire history reachable from the pushed
    tip**: every path ever added against the forbidden-path regex, every line ever
    added against the forbidden terms (case-insensitively) and against
    `local/identifiers.txt` when present, then gitleaks. A commit that got in with a
    hook bypass, an amend or a rebase is still caught, and a file added and deleted
    again is too. Then the build gate, unless the skip variable is exactly `1`.
  - `.claude/settings.json` + `tool/claude-guard.sh` — a Claude Code `PreToolUse` hook
    that refuses hook bypasses (the no-verify flag and its prefixes, `-n`,
    `core.hooksPath`, `GIT_DIR`), force pushes in every spelling (`--forc…`, `-f`,
    `+ref`), refspec deletion (`:ref`, `--delete`), `git branch -d/-D`, `git tag`
    (except `-l`), `filter-repo`, `git add .`/`-A`/`./`/`:/`/`*`, hard resets, the
    gate-skip variables in any spelling, and `checkout`/`restore` of a path. It
    matches the command *text*, so a Bash command that merely spells one of those is
    refused too. What to do instead: search for a forbidden spelling with the Grep or
    Read tool, never `grep` in Bash; write a file that must contain one with the
    editor tool; put a commit message that must mention one in a file and use
    `git commit -F`; read `.git/config` instead of `git config --get core.hooks…`.
    Fails closed without `jq`, and the settings entry exits 2 if the guard cannot
    start.
  - CI `secrets-scan` (gitleaks, full history) and `tracked-paths` (paths and
    forbidden terms) — the same checks on a machine whose hooks were never installed.
  - `tool/install-git-hooks.sh` sets `core.hooksPath`; `tool/bootstrap.sh` and
    `tool/gate.sh` run it. A guard nobody remembers to install is not a guard.
- **Never `--no-verify`.** If a hook is wrong, fix the hook.
- The forbidden-terms scan is a heuristic against the obvious spelling: a term split
  across two lines or escaped in JSON passes it. It exists so an honest paste is
  refused, not to stop a determined author; the reviewer's eye is the second layer.
- Three ways a shell guard fails, all paid for and all written into every guard here.
  Do not "simplify" any away:
  - `git grep`/`grep` exit 1 when nothing matches; under `set -e` + `pipefail` that
    aborts the hook on the clean tree it should let through. Every scan pipeline ends
    in `|| true` and the result is counted, never tested for exit status. The first
    version of `pre-push` refused every clean push this way.
  - `grep -q` exits at the first match, SIGPIPEs the upstream command, and under
    `set -o pipefail` that 141 makes the test **false**. Capture and count instead.
  - One NUL byte anywhere in a stream makes grep call the rest binary and stop
    matching. Every grep in a guard passes `-a`.
- **Prove any change to a guard by watching it refuse.** A throwaway staged file that
  should be blocked and an ordinary edit that should pass, for a hook; a deliberately
  broken fixture, for `check_docs` (its test suite does exactly that). A guard that has
  only ever been seen saying yes has not been tested. The first commit of this repo was
  refused by its own forbidden-terms check; that was the proof.
- Make the broken input in a copy of the repo under `/tmp`, not in place.
- A leak already in history is not fixed by a new commit. **Stop and tell the user**:
  rotating the credential comes first, and the history rewrite (a replace-text
  filter and a force push) is the user's operation outside this session — the guard
  refuses every spelling of it on purpose. Assume anything already cloned, forked or
  cached stays out.

## The token

- The channel JWT travels in the WebSocket subprotocol list (`['bearer', token]`),
  never in the URL, where it would land in access logs.
- It must never reach a log line, at any level. Client-side logs carry the channel
  and game ids, the user id, the zone (through `Normalize.diagnostic`), the tick, close
  codes, reason *lengths*, SDK-authored dispositions and reasons, attempt counts,
  delays and the map URL's length — and nothing the peer chose beyond those. There
  is a test for this in both client suites and in the end-to-end suite, each with a
  positive control.
- **The token crosses a public extension point.** `GatewayWebSocketFactory.connect` is
  handed `GatewayWebSocketRequest.subprotocols`, which is `['bearer', '<the raw
  JWT>']`. A credential crossing an extension point needs the warning at the extension
  point: it is in the `///` comment on `subprotocols`, so it reaches the implementer's
  IDE.
- A subprotocol carrying non-token characters is refused at construction rather than
  at connect time — but **that refusal's message names the index, never the
  character**. The second subprotocol *is* the token; one character of it in an
  `ArgumentError` is one character in whatever caught it.
- `auth_client` never logs, throws or returns a message containing the token, the
  provider credential, a response body or a URL with a fragment; `AuthFailure` is a
  kind and a status. `ChannelToken.toString()` omits the JWT. `parseRedirect` compares
  the nonce in constant time and tells the caller to discard the URI.

## Building what goes out

- **Escape at one choke-point, and test the escaping.** Every frame goes through
  `LobbyFrameWriter` / `Json.encode`; every URL through `buildGatewayUrl` or
  `Uri.replace`. Never assemble one by string concatenation elsewhere.
- **A size cap is in bytes; a string length is in characters.** Every limit the gateway
  states is bytes; measure with `utf8.encode(...).length`.
- Never interpolate untrusted data into a wire protocol. The client's own fields are no
  exception: a zone name or a `dir` built from player input is peer data by the time it
  reaches the frame.

## What not to log

- Never a receive buffer or a frame body. It is whatever the peer just sent. Log its
  size or its `type` — and a `type` only through `Normalize.diagnostic`, which caps it
  at 32 characters and strips control characters, because it is a peer-chosen string.
- Never a close reason's text; log its length. The gateway may quote what the client
  sent back into it.
- Never an `event` payload, a `q` frame, or a `map()` body. `debug` is not an
  exemption: a consumer plugs in a writer that persists forever.
- For a refusal, log the code, not the message.
- A URL the server named is not safe to log either: `mapUrl` is public today, but a
  pre-signed one would put its signature in a persistent writer. Log the length.
- **An exception message built from the input is a frame body.** `FormatException`
  quotes the JSON; `WebSocketException` and `ClientException` name the URL; `dart:io`'s
  `ArgumentError` for a bad scheme or host quotes the whole URI; `Uri.parse` quotes the
  text it failed on, fragment included. None of them crosses a package boundary or
  reaches a log: the map fetcher validates `mapUrl` (absolute `http(s)`, a host)
  before `dart:io` sees it and maps the rest to `MapFetchException` reasons; the auth
  client maps `ArgumentError` to an `AuthFailure` kind; the example parses a pasted
  URL with `Uri.tryParse`. A `dir` that is too long is reported by its byte length,
  not its text.

## Trusting the wire

- `enter` and `leave` are the gateway's own bookkeeping on `q`; the client refuses to
  send them locally. Removing that check is a regression, not a simplification.
- Capability checks in this SDK are a courtesy that gives a fast local error; the
  gateway enforces them. Never treat a client-side check as the enforcement.
- The map asset is public and immutable, so the request carries no credentials. Keep
  it that way: adding a header there sends the token to a CDN. The fetcher still has
  one deadline for headers and body (a per-chunk timeout lets a drip-feed run for
  hours), a 16 MiB cap enforced while streaming, a redirect budget, and a cache that
  holds one URL, because the URL came off the wire and a gateway may rotate it. The
  auth client caps a response at 1 MiB before buffering it.
- The 64 KiB inbound cap is checked after `web_socket_channel` assembled the message;
  it bounds what reaches the SDK, not the transport's own allocation. A cap inside
  the frame assembly needs a transport of our own; until then the gateway's 32 KiB
  outbound cap is the real bound and a non-gateway peer is a known gap.

## Review habit

- A change touching the **wire protocol, the token, a guard, or what reaches a log
  line** takes security as its third review angle ([workflow.md](workflow.md)).
- **The leak is usually one level up from the secret.** Logging a whole frame to report
  a refusal prints the payload; logging a close reason prints what the peer chose;
  logging an exception message prints the input. Log the decision, not the object
  that carried it.
