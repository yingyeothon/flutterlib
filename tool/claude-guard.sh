#!/usr/bin/env bash
# Claude Code PreToolUse hook (.claude/settings.json): refuses the Bash commands that
# rules/workflow.md and rules/security.md forbid, before they run. Git hooks cannot
# catch a hook bypass, so this is the layer that does.
#
# It matches the command TEXT, so a command that merely spells a forbidden flag
# inside a string (a heredoc writing this file, say) is refused too; write such
# files with the editor tool instead.
#
# Fails CLOSED: no jq, or unreadable input, is a refusal (exit 2), not a pass.
set -uo pipefail

command -v jq >/dev/null || { echo "claude-guard: jq is required (apt install jq)" >&2; exit 2; }

input=$(cat) || { echo "claude-guard: could not read the tool input" >&2; exit 2; }
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null) || { echo "claude-guard: could not parse the tool input" >&2; exit 2; }

# Git accepts any unambiguous prefix of a long option, so the patterns match the
# shortest unambiguous prefix (--no-v, --forc, --har), the short forms (-n, -f), the
# refspec forms (+ref, :ref), the hook-bypass knobs and the gate-skip variables in
# any spelling. `git tag -l` / `--list` is the one tag form allowed.
pattern='(--no-v|--forc|git commit[^|;&]* -[a-zA-Z]*n|git push[^|;&]* -[a-zA-Z]*f|git push[^|;&]* \+[A-Za-z]|git push[^|;&]* :[A-Za-z]|filter-repo|git add( -A| --all| \.| \./| :/| \*)( |$)|reset[^|;&]* --har|git tag( |$)|git branch[^|;&]* -[dD]|push[^|;&]*--del|core\.hooksPath|GIT_DIR=|GIT_WORK_TREE=|SKIP_CI_GATE|SKIP_EXAMPLE_GATE|git checkout( --)? [^-][^ ]*( |$)|git restore [^-]|git restore --worktree|git restore -W)'
# The allowed tag forms are blanked out of the text, not the whole line, so a
# forbidden command chained after `git tag -l` is still seen.
hits=$(printf '%s\n' "$cmd" | sed -E 's/git tag (-l|--list)/git tag-list/g' | grep -a -c -E -- "$pattern" || true)
if [ "${hits:-0}" -gt 0 ]; then
  echo "claude-guard: refused — this command is forbidden by rules/workflow.md or rules/security.md (no hook bypass, no force push or refspec force, no filter-repo, no git add ./-A, no hard reset, no tag or branch deletion, no gate-skip variable, no checkout/restore of a tracked file)." >&2
  exit 2
fi
exit 0
