# Repository Instructions

## Project Shape

- `flutterlib` holds the Dart client libraries of the yyt platform, ported from
  [tslib](https://github.com/yingyeothon/tslib) and
  [csharplib](https://github.com/yingyeothon/csharplib): `packages/yingyeothon_*` are
  pure Dart (no Flutter import) so `dart test` covers them, and `examples/playground`
  is the Flutter app that shows them wired together.
- Seven packages in one pub workspace: `codec`, `logger`, `event_broker`,
  `gamebase_client` (the gateway SDK), `auth_client`, `kvstore_client` (the key-value
  store client), and `fake_gateway` (an in-process gateway and `/kv/*` store for tests
  and the offline demo; never published).
- Source of truth documents:
  - `CONVENTIONS.md` — Dart API design rules. Canonical; do not restate or contradict.
  - `README.md` — what the library is for, the package list and the dependency graph.
  - `docs/` — the consumer's integration guide, indexed by `docs/README.md`.
  - Each `packages/<name>/README.md` — that package's public API and its deliberate
    differences from the tslib and csharplib originals.
  - `rules/documentation.md` says which layer owns what. One fact, one owner.
- The normative wire spec for `gamebase_client` is the gateway's own README and
  `gateway/internal/lobby/protocol.go` in the `service` repository, not tslib. For
  `kvstore_client` it is `services/state/README.md` (_KV routes_) and
  `packages/console-db/src/kvstore.ts` there; `KvRules` copies its constants.

## Required Rule Lookup

- Before non-trivial work, open `rules/index.md` and the relevant rule files.
- Keep this file short; put reusable lessons in `rules/`.
  (`AGENTS.md` is a symlink to this file — edit `CLAUDE.md` only.)
- After each completed task, fold any **durable** lesson into the relevant `rules/*.md`
  (and `rules/index.md` if files were added or removed). "Nothing durable" is an
  answer; say it.

## Essential Commands

```bash
tool/bootstrap.sh                       # once: pub get, git hooks, tool check
tool/gate.sh                            # the green gate; pre-push runs exactly this, CI adds a Linux build
dart run tool/bin/check_coverage.dart   # per-package floor, line 80 / branch 70
dart run tool/bin/check_docs.dart       # links, index, diagrams, public API coverage
cd examples/playground && flutter create . --platforms=linux --project-name yyt_playground --org life.yyt && flutter run -d linux
```

## Non-Negotiables

- Follow `CONVENTIONS.md` and `rules/architecture.md` for every public symbol.
- No `package:flutter` under `packages/`; platform glue lives in the app —
  `rules/flutter.md`.
- Never interpolate untrusted data into a wire protocol, and never log a token, a frame
  body, a payload, a close reason or a URL that came off the wire; log ids, codes and
  lengths — `rules/security.md`.
- New or changed behavior ships with tests; the pure suite reaches the coverage floor
  without the integration tag — `rules/testing.md`.
- A changed public surface updates the barrel's `show` list, the doc comment **and** the
  package README's `## Public API` in the same commit — `rules/documentation.md`.
- Verify on `flutter run -d linux` with the offline demo before calling a change done —
  `rules/manual-verification.md`.
- **Work on `main`; commit then push.** No topic branches, no `--force`, no
  `--no-verify` — `rules/workflow.md`.
- Follow the per-task completion ritual in `rules/workflow.md`, including its
  three-subagent adversarial review before every commit that is not covered by the
  narrow exemption in that file.
- A release is a git tag the user cuts; every package carries one version —
  `rules/release.md`, `rules/deployment.md`.
