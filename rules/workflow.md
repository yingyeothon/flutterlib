# Workflow

## Working agreement

- **Work on `main` and push.** Upstream is `git@github.com:yingyeothon/flutterlib.git`.
  Finish a task with `git commit` then `git push`; `pre-push` runs the whole gate
  before anything leaves the machine, so no branch is needed "to be safe".
- A push rejected as non-fast-forward is `git pull --rebase`, re-run the gate, push.
  **Never `--force`** — `security.md` reserves a history rewrite for a leak. If you must
  stop mid-task, leave the tree uncommitted and say what is unfinished rather than
  pushing a partial change to a public `main`.
- Talk to the user in Korean; write all repository content — code, comments, READMEs,
  `docs/`, rules, commit messages — in English. `check_docs` refuses Korean outside a
  code span. The audience for `docs/` is a game developer who may not read Korean.
- Commit messages are English, imperative, one coherent purpose per commit.
- Stage intentionally, by path. Never `git add .` or `git add -A`: `.dart_tool/` and
  `.claude/` are git-ignored and safe, but a scratch app, a platform folder or a file
  you did not mean to publish is not — and this repo is public. Run
  `git status --porcelain` first, then name each path.
- Work may be delegated to subagents, but **a review subagent reports; it never
  writes.** Tell each one explicitly: read only — no `Edit`, no `Write`, no
  `git add/commit/push/checkout/restore/stash`, no `dart`/`flutter` commands. Only the
  main session runs the tools, edits the tree or touches git.
- **Do not edit any other repository under `~/git/yyt.life/`.** `service`, `tslib` and
  `csharplib` are read here — the gateway's Go source is the normative wire spec — and
  that access is read-only.
- The repo is **public**. Never `--no-verify`, and never `git reset --hard` with
  uncommitted work in the tree. `.claude/settings.json` installs a Claude Code guard
  that refuses those commands; if it blocks something legitimate, fix the guard, do not
  route around it.
- **`git checkout -- <file>` discards that file's unstaged edits**, silently. Make a
  throwaway experiment in a copy of the repo under `/tmp`, not in place.
- Releases are git tags and are the **user's** call — `release.md`.
- `.claude/handover.md` is a **session note, not a rule**: where it and `rules/`
  disagree, `rules/` wins. Check its premise against `git log` before executing it; if
  the premise is gone, say so and delete it.

## Per-task completion ritual

1. Make the change testable, then cover the new or changed behaviour
   ([testing.md](testing.md)). Prose and rule files have no behaviour to cover — say
   so rather than inventing a test that cannot fail.
2. Verify beyond the unit tests, at the **highest** level the change reaches
   ([manual-verification.md](manual-verification.md)):
   1. runtime or wire behaviour → the offline demo on `flutter run -d linux`, and the
      dev gateway when a credential is at hand;
   2. anything the example compiles — a package's public surface, the example itself →
      `flutter analyze`, `flutter test` and a Linux run of the example;
   3. `docs/`, `rules/` and scripts → the green gate, **and if the change altered a
      guard**, watching that guard refuse something ([security.md](security.md)).

   Name every level you ran and every one you skipped, with the reason. "Not
   applicable" is an answer; silence is not.
3. **Run three fresh-context subagents to review the change adversarially, in
   parallel, before committing — mandatory, not a judgement call.**
   - **Exempt, and only this: a change to text no tool reads and no reader sees** —
     an implementation comment (`//`) that is *not* a `///` doc comment, whitespace
     `dart format` would produce, or a git-ignored file that is never committed.
     Everything else is reviewed, including a `///` typo, a new or changed test, and
     any version bump. If you are arguing about whether a change qualifies, it does
     not. Say which path you took.
   - Use a genuinely fresh context — a `general-purpose` agent, **never a fork**, which
     inherits this session and would review its own reasoning.
   - Hand each the **same explicit file list**: `git status --porcelain` *and*
     `git diff`, plus the untracked files by name. A bare diff hides every untracked
     file, which is exactly what a new rule file or a new test is.
   - Reviewers verify against the checked-in sources as they stand; they do not run
     tools. A claim that only a test run can settle comes back as unverified, and the
     main session runs it.
   - Tell each to assume the work is wrong: a reviewer asked to "check this over"
     reports that it looks fine.

   Two angles are fixed — **correctness against the sources** (every claim, signature
   and constant cited against the Dart sources, the tests, and the gateway README for
   anything on the wire, plus a list of what could not be verified) and **the
   consumer's experience** (walk it as the Flutter developer: does it compile, is
   anything missing, what will they misread). The third is chosen for the change,
   most-expensive-defect first: *security* if it touches the wire, the token, a guard
   or what reaches a log line ([security.md](security.md)); otherwise *concurrency and
   ordering* if it touches the state machine, reconnect, the emitter or settlement;
   otherwise *editing and structure*.
4. Fold durable lessons into `rules/*.md`; update `rules/index.md` if files changed.
   Then send **the rule diff only** to a fourth fresh reviewer with one question:
   *can an agent with no memory of this session follow this exactly, and what will it
   do when it cannot?*
5. Apply the feedback from all four. A finding you disagree with is answered by
   checking the source, not by weighing the reviewer's confidence. Re-run a reviewer
   only when this step changed the substance of what it read. Name what the reviewers
   found and what you rejected, with the reason.
6. Run the green gate below, then commit and push to `main`.

## Green gate

```bash
tool/gate.sh
```

It runs, in order: hook install, `dart pub get`, `dart format --set-exit-if-changed`,
`dart analyze --fatal-infos packages tool`, `dart test` in every member (integration
tag included), `check_coverage`, `check_docs`, and `flutter pub get / analyze / test`
for every example. `pre-push` and CI run exactly this, so this is a way to see the
failure early rather than a step anyone can forget.

**A gate that was already red before your change is a separate task.** Confirm with
`git stash && tool/gate.sh`. Do not fold the repair into your commit and do not push
over it. `SKIP_CI_GATE=1 git push` turns the build gate off (the secret scans still
run) and `SKIP_EXAMPLE_GATE=1` skips the Flutter half — **do not use either** for a red
tree or a slow one; they exist for a machine without the SDK, and the Claude Code
guard refuses them.

## Scope decisions already made

- Six packages, no more without a reason that survives "can this run on a phone?".
- The gateway wire protocol is owned by the `service` repository. When it changes,
  this SDK follows it — never the other way round.
- The example is one app (`playground`) that exercises every package; a second
  example needs a purpose the first cannot carry.
