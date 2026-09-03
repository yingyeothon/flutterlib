# Deployment

Nothing in this repository deploys to a store or a server: the libraries ship as a
git tag (`release.md`) and the example app has no store identity, no signing and no
build environment file. "Deploy" here means "make a change reachable by a consumer",
and the decision flow is:

1. **Decide what kind of change it is.**
   - Docs, rules or tooling only → no version bump; push to `main` is the deployment.
   - A library change consumers should pick up → a version bump and a tag.
   - A breaking change (`0.x`: a removed or renamed export, a changed default) → a
     minor bump, and the package README's `## Differences` or a `docs/` note says what
     moved.
2. **When the change does not make this obvious, confirm with the user before
   bumping.** Say which files the bump touches and which behaviour changed.
3. **Ask which artifact.** Today the only one is a tag; pub.dev publishing would be a
   second artifact and is not enabled. For the example there is no artifact: it is
   built from source on the consumer's machine after `flutter create .`.
4. **Build and verify the artifact.** After the user cuts the tag, install it from a
   fresh `flutter create` app under `/tmp` by git dependency and run a client
   construction (`release.md`, *Verifying a tag*). A tag that does not install is not
   released; the fix is the next patch tag.

What this file is not: a recipe for shipping a game. A game that embeds these
packages has its own deployment rules (signing, store listing, `--dart-define`
secrets) in its own repository.
