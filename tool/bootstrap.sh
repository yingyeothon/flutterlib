#!/usr/bin/env bash
# One-time setup after cloning: resolve the workspace, install the git hooks, and
# say which optional tools are missing. Safe to re-run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tool/install-git-hooks.sh
dart pub get

for bin in gitleaks flutter jq; do
  command -v "$bin" >/dev/null || echo "bootstrap: NOTE — '$bin' is not on PATH (gitleaks: every commit is refused without it; flutter: tool/gate.sh and every push are red until it is installed; jq: the Claude Code guard fails closed)." >&2
done

# The private ops setup generates a list of host/DB/account patterns in the sibling
# `service` checkout. When it is there, copy it so the hooks scan for those names too.
# The file is git-ignored here (local/), and the hooks work without it.
src=../service/local/identifiers.txt
if [ -f "$src" ] && [ ! -f local/identifiers.txt ]; then
  mkdir -p local && chmod 700 local
  cp "$src" local/identifiers.txt && chmod 600 local/identifiers.txt
  echo "bootstrap: copied $src to local/identifiers.txt ($(wc -l < local/identifiers.txt) patterns)"
fi

echo "bootstrap: done — run tool/gate.sh to see the full gate green"
