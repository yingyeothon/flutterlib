#!/usr/bin/env bash
# Points git at tool/git-hooks. Run it once after cloning:
#
#   tool/install-git-hooks.sh
#
# tool/bootstrap.sh and tool/gate.sh both run it, so in practice nobody has to
# remember. It is idempotent and cheap.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

want=tool/git-hooks
have=$(git config --get core.hooksPath || true)

chmod +x "$want"/* 2>/dev/null || true

if [ "$have" = "$want" ]; then
  status="already set"
elif [ -n "$have" ]; then
  echo "install-git-hooks: core.hooksPath is '$have', not '$want'." >&2
  echo "install-git-hooks: refusing to overwrite someone else's hooks — set it yourself if that is what you want:" >&2
  echo "  git config core.hooksPath $want" >&2
  exit 1
else
  git config core.hooksPath "$want"
  status="set"
fi

echo "install-git-hooks: core.hooksPath $status to $want"

# The hooks exit non-zero without gitleaks rather than waving a commit through, so a
# missing binary is worth saying now instead of at the next commit.
if ! command -v gitleaks >/dev/null; then
  echo "install-git-hooks: WARNING — gitleaks is not installed, so every commit will be refused." >&2
  echo "install-git-hooks: apt install gitleaks   (or) brew install gitleaks" >&2
fi
