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
  - `tool/git-hooks/pre-push` — re-checks the pushed tip's whole tree, scans it for the
    forbidden terms, scans the **entire history reachable from that tip** for private
    identifiers and with gitleaks, so a commit that got in with `--no-verify`, an
    amend or a rebase is still caught. Then the build gate, unless `SKIP_CI_GATE=1`.
  - `.claude/settings.json` + `tool/claude-guard.sh` — a Claude Code `PreToolUse` hook
    that refuses `--no-verify`, `--force`, `filter-repo`, `git add .`, `reset --hard`,
    tags, branch deletion and the gate skips before they run. Fails closed without
    `jq`.
  - CI `secrets-scan` (gitleaks, full history) and `tracked-paths` (paths and
    forbidden terms) — the same checks on a machine whose hooks were never installed.
  - `tool/install-git-hooks.sh` sets `core.hooksPath`; `tool/bootstrap.sh` and
    `tool/gate.sh` run it. A guard nobody remembers to install is not a guard.
- **Never `--no-verify`.** If a hook is wrong, fix the hook.
- Two ways a shell guard fails open, both paid for in the `service` repo and both
  written into every guard here. Do not "simplify" either away:
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
- A leak already in history is not fixed by a new commit. Rewrite it
  (`git filter-repo --replace-text`) and force-push, and assume anything already
  cloned, forked or cached stays out. If a real credential ever lands here, rotating
  it comes first.

## The token

- The channel JWT travels in the WebSocket subprotocol list (`['bearer', token]`),
  never in the URL, where it would land in access logs.
- It must never reach a log line, at any level. Client-side logs name the channel,
  the game, the user id and the close code — nothing else. There is a test for this in
  both client suites and in the end-to-end suite, each with a positive control.
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
  quotes the JSON; `WebSocketException` names the URL; `ClientException` names the
  URL. None of them crosses a package boundary or reaches a log; each is mapped to a
  code.

## Trusting the wire

- `enter` and `leave` are the gateway's own bookkeeping on `q`; the client refuses to
  send them locally. Removing that check is a regression, not a simplification.
- Capability checks in this SDK are a courtesy that gives a fast local error; the
  gateway enforces them. Never treat a client-side check as the enforcement.
- The map asset is public and immutable, so the request carries no credentials. Keep
  it that way: adding a header there sends the token to a CDN. The fetcher still has a
  timeout, a 16 MiB cap and a redirect budget, because the URL came off the wire.

## Review habit

- A change touching the **wire protocol, the token, a guard, or what reaches a log
  line** takes security as its third review angle ([workflow.md](workflow.md)).
- **The leak is usually one level up from the secret.** Logging a whole frame to report
  a refusal prints the payload; logging a close reason prints what the peer chose;
  logging an exception message prints the input. Log the decision, not the object
  that carried it.
