#!/usr/bin/env bash
# Claude Code PreToolUse hook (.claude/settings.json): refuses the Bash commands that
# rules/workflow.md and rules/security.md forbid, before they run. Git hooks cannot
# catch `--no-verify`, so this is the layer that does.
#
# Fails CLOSED: no jq, or unreadable input, is a refusal (exit 2), not a pass.
set -uo pipefail

command -v jq >/dev/null || { echo "claude-guard: jq is required (apt install jq)" >&2; exit 2; }

input=$(cat) || { echo "claude-guard: could not read the tool input" >&2; exit 2; }
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || { echo "claude-guard: could not parse the tool input" >&2; exit 2; }

pattern='(--no-verify|--force|--force-with-lease|git push[^|;&]* -f( |$)|filter-repo|git add( -A| --all| \.)( |$)|git reset --hard|git tag |push[^|;&]*--delete|SKIP_CI_GATE=|SKIP_EXAMPLE_GATE=|git checkout -- |git checkout [^-][^ ]* -- )'
hits=$(printf '%s\n' "$cmd" | grep -a -c -E -- "$pattern" || true)
if [ "${hits:-0}" -gt 0 ]; then
  echo "claude-guard: refused — this command is forbidden by rules/workflow.md or rules/security.md (no --no-verify, --force, filter-repo, git add ., reset --hard, tags, branch deletion, gate skips, or checkout of a tracked file)." >&2
  exit 2
fi
exit 0
