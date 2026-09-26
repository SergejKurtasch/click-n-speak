#!/bin/bash
# PostToolUse hook: after a successful `git commit`, ask Codex to review the
# compact project guide through the `update-codex-md` skill.
#
# Exits 0 silently when the invocation isn't a git commit — the hook fires on
# every Bash call, so most invocations must be no-ops.

set -euo pipefail

# Read the tool-call payload.
payload=$(cat)

# Extract fields with python3; jq is not guaranteed on every machine. Fail
# quietly if Python is unavailable or parsing breaks.
decision=$(
    python3 - "$payload" <<'PY' 2>/dev/null || echo "skip"
import json
import re
import sys

try:
    data = json.loads(sys.argv[1])
except (json.JSONDecodeError, TypeError):
    print("skip")
    sys.exit(0)

tool_name = data.get("tool_name") or ""
if tool_name not in {"Bash", "exec", "exec_command"}:
    print("skip")
    sys.exit(0)

tool_input = data.get("tool_input") or {}
cmd = tool_input.get("command") or tool_input.get("cmd") or ""
if isinstance(cmd, list):
    cmd = " ".join(str(part) for part in cmd)
if not isinstance(cmd, str):
    print("skip")
    sys.exit(0)

# Match `git commit` as a standalone subcommand, not `git commit-tree`.
if not re.search(r"(^|[;&|\s])git\s+commit(\s|$)", cmd):
    print("skip")
    sys.exit(0)

# Only nudge on successful commits. A failed pre-commit hook or conflict
# should not trigger doc-review noise.
resp = data.get("tool_response") or {}
if not isinstance(resp, dict) or resp.get("exit_code") != 0:
    print("skip")
    sys.exit(0)

# Commits that only amended the message (no files staged) also skip.
stdout = str(resp.get("stdout") or "") + str(resp.get("output") or "")
if "nothing to commit" in stdout.lower():
    print("skip")
    sys.exit(0)

print("trigger")
PY
)

if [ "$decision" != "trigger" ]; then
    exit 0
fi

# Inject a reminder into Codex's context via the PostToolUse JSON contract.
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "A git commit just landed in this project. Invoke the `update-codex-md` skill and inspect HEAD. If the commit changes project architecture, the module map, canonical commands, or cross-module invariants, update the tracked AGENTS.md compactly; otherwise report that no update is needed."
  }
}
JSON
