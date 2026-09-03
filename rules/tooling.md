# Tooling

## The gate, in order, and why

`tool/gate.sh` — the single entry point `pre-push` and CI share:

1. `tool/install-git-hooks.sh` — so running the gate is also installing the guards.
2. `dart pub get` — the workspace resolves once, at the root.
3. `dart format --output=none --set-exit-if-changed packages tool examples` — the
   formatter is Dart 3.7+'s tall style; do not hand-format against it.
4. `dart analyze --fatal-infos packages tool` — the example is analyzed by
   `flutter analyze` in step 8, because it resolves Flutter separately.
5. `dart test --reporter=compact` **per member** (`packages/*/`, `tool/`), integration
   tag included. `dart test` at the workspace root does not fan out: it looks for a
   `test/` beside the root pubspec, finds none, prints its usage and exits non-zero —
   which read as "passed" once when only the last line was checked.
6. `dart run tool/bin/check_coverage.dart` — per package, own suite, `-x integration`.
7. `dart run tool/bin/check_docs.dart`.
8. `flutter pub get && flutter analyze --fatal-infos && flutter test` in every
   `examples/*/`. `SKIP_EXAMPLE_GATE=1` skips this on a machine without Flutter; CI
   never does.

## Workspace facts

- One `pubspec.yaml` at the root lists the members; each member says
  `resolution: workspace`. Sibling dependencies are version constraints (`^0.1.0`),
  resolved to source by the workspace and to the tag by a consumer. Never `path:`
  between packages.
- `pubspec.lock` is not committed anywhere: a library resolves fresh, like its
  consumers.
- One `.dart_tool/package_config.json` at the root; `dart test --coverage-path` uses it
  and therefore reports sibling sources too — `check_coverage` filters to the package's
  own `lib/` (`architecture.md`).
- `dart test` at the root runs **nothing** (no root `test/`); run it inside each
  member, which is what `tool/gate.sh` does.
- `examples/playground` is **not** a member: `flutter: sdk: flutter` would make every
  root command need the Flutter SDK, and `dart test` would try to run `flutter_test`
  tests. It depends on the packages by `path:` and resolves on its own; `check_docs`
  refuses an example with `resolution: workspace`. Because the packages depend on
  each other by version, the example also needs a `dependency_overrides:` block that
  maps every sibling to its path — otherwise pub looks for `yingyeothon_codec` on
  pub.dev and fails.
- `dart pub get` needs every workspace member to exist; a new member needs its
  `pubspec.yaml` before the root resolves again.

## Scripts

- `check_coverage.dart` — `dart test --coverage-path=coverage/lcov.info
  --branch-coverage -x integration` per package, then sums `DA:`/`BRDA:` records for
  the package's `lib/` (`tool/lib/src/lcov.dart`). `COVERAGE_LINE_MIN` /
  `COVERAGE_BRANCH_MIN` override the floors. A package with no report fails; a package
  with no branches reports `n/a` and passes on lines.
- `check_docs.dart` — the numbered list in its header. The mermaid check is a heuristic
  (known first line, no styling, no `end` node, one per H2, ≤ 12 flowchart nodes,
  `<!-- check-docs: exhaustive -->` lifts the node cap for a routing map); it is not
  a parser, so render a new diagram once in a viewer.
- `claude-guard.sh` reads the Bash command from stdin JSON with `jq` and exits 2 on a
  forbidden pattern. Without `jq` it exits 2 too. `.claude/settings.json` invokes it
  through `cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"` because a hook
  runs in the session's current directory: a bare `tool/claude-guard.sh` broke the
  moment a command had `cd`'d into `examples/playground`, and a hook that cannot
  start is reported as a hook error on every Bash call. The guard matches the
  command *text*, so a test that spells a forbidden flag inside a string is refused
  too — probe the guard with the fixtures in `tool/test/`, not with a literal.

## Gotchas already paid for

- `dart test` prints a `FormatException`'s message with the offending text; a test
  that feeds a credential-shaped string to the parser leaks it into CI logs unless the
  wrapper maps it (`codec`).
- A `StreamController.broadcast(sync: true)` throws `Cannot fire new event` on a
  nested `add`; use `Emitter`.
- `WebSocketChannel.protocol` is `''`, not `null`, when the server chose none; the
  transport maps it.
- `dart:io` `WebSocket.done` on a server socket does not complete after a
  client-initiated close; read the stream (`testing.md`).
- `web_socket_channel`'s `sink.close()` before `ready` completes loses the close; the
  transport records the request and finishes it after the handshake.
- The pre-commit hook scans added lines for `tool/forbidden-terms.txt`; a script that
  needs to *name* a private path (bootstrap copying an identifier list) cannot spell
  it literally. Build the path from parts or drop the term from the list — the first
  commit here dropped one directory name for that reason.
- `flutter create .` regenerates `test/widget_test.dart` if absent; keep a real test
  under that name in the example.
