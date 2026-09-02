#!/bin/sh
# Refresh the code-monkey index after something moved the working tree underneath it.
#
# Byte offsets in the index are only meaningful against the bytes they were recorded
# from, so a checkout, merge or rebase invalidates every one of them at once. Reads
# that slice source refuse rather than print garbage; this is what keeps them from
# having to.
#
# Shared by the git hooks beside it and by the Claude Code PostToolUse hook in
# .claude/settings.json, so both refresh the index the same way.
#
# Never fails the operation it is attached to. A missing binary or a directory that was
# never indexed is not an error here — it just means there is nothing to do.

command -v code-monkey >/dev/null 2>&1 || exit 0

# CLAUDE_PROJECT_DIR is set when Claude Code calls this; git hooks fall back to the repo
# root. Either way the project is resolved explicitly rather than from the caller's cwd.
root=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}
[ -n "$root" ] || exit 0
[ -d "$root/.code-monkey" ] || exit 0

# Incremental: hashes every file, reparses only what changed. ~20ms when nothing did.
code-monkey index --project "$root" >/dev/null 2>&1 || true
exit 0
