# Release

## What a release is

- **A git tag on `main` is the release**, `vX.Y.Z`. Consumers install by git dependency
  pinned to it:

  ```yaml
  dependencies:
    yingyeothon_gamebase_client:
      git:
        url: https://github.com/yingyeothon/flutterlib.git
        path: packages/yingyeothon_gamebase_client
        ref: vX.Y.Z
  ```

  Nothing is published to pub.dev and no CI job holds a publish credential. If that
  ever changes it is a decision recorded here first.
- Every package carries **one version** in its `pubspec.yaml`; siblings are `path:`
  dependencies, so one `ref:` pins them all together. `check_docs` fails when the
  packages under `packages/` disagree; `tool/pubspec.yaml` carries the same version by
  hand and is not gated.
- `0.x`: a breaking change bumps the minor, everything else the patch.

## Cutting one

1. The green gate and the manual verification (`manual-verification.md`) on the commit
   to be tagged — the offline demo, and the dev gateway when possible.
2. Bump `version:` in every `packages/*/pubspec.yaml` and `tool/pubspec.yaml`
   and `tracerSdkVersion` in `tracer_client/lib/src/tracer_client.dart` (a test
   fails until it matches), then regenerate the tracer golden (`testing.md`)
   (`examples/playground/pubspec.yaml` is the app's own version: leave it). Then, by
   hand — nothing gates these — set `ref: vX.Y.Z` in every git `## Install` snippet
   (every package README except `fake_gateway`'s, `README.md`,
   `docs/getting-started.md`; `git grep -n 'ref: v'` lists them, plus this file's
   two prose lines), and set `fake_gateway`'s workspace dev-dependency snippet to
   `^X.Y.Z` (`git grep -n 'fake_gateway: ^'`; it takes no `ref:`).
3. Commit that as its own commit (`Release vX.Y.Z`). **The agent stops here**: it does
   not tag.
4. The user runs:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push --atomic origin main vX.Y.Z
   ```

5. Never move or delete a tag. A mistake is the next patch version.

## Verifying a tag

- Before tagging, install the package the way the README says — as one consumer
  would — from a local `path:` and from the pushed commit: v0.3.0 shipped a two-package
  tracer snippet that never resolved (a sibling `path:` dependency is read as the
  tag's commit, a different source from `ref: v0.3.0`), and only the post-tag check
  found it; v0.3.1 re-exports instead. A multi-package install names one package.

- In a fresh `flutter create` app under `/tmp`, add the git dependency with the new
  `ref:` and run `flutter pub get` and a `main.dart` that constructs a client. That is
  the consumer's path and the only proof the tag installs.
