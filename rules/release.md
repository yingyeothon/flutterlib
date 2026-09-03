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
        ref: v0.1.0
  ```

  Nothing is published to pub.dev and no CI job holds a publish credential. If that
  ever changes it is a decision recorded here first.
- Every package carries **one version** in its `pubspec.yaml`, and sibling constraints
  (`yingyeothon_codec: ^0.1.0`) must admit it. `check_docs` fails when the packages
  disagree. `fake_gateway` and `tool` carry the same version for the same reason even
  though they are never installed.
- `0.x`: a breaking change bumps the minor, everything else the patch.

## Cutting one

1. The green gate and the manual verification (`manual-verification.md`) on the commit
   to be tagged — the offline demo, and the dev gateway when possible.
2. Bump `version:` in every `packages/*/pubspec.yaml` and `tool/pubspec.yaml`; update
   the `ref:` in every `## Install` snippet and in `docs/getting-started.md`.
3. Commit that as its own commit (`Release vX.Y.Z`). **The agent stops here**: it does
   not tag.
4. The user runs:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push --atomic origin main vX.Y.Z
   ```

5. Never move or delete a tag. A mistake is the next patch version.

## Verifying a tag

- In a fresh `flutter create` app under `/tmp`, add the git dependency with the new
  `ref:` and run `flutter pub get` and a `main.dart` that constructs a client. That is
  the consumer's path and the only proof the tag installs.
