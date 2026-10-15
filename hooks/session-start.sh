#!/usr/bin/env bash
# SessionStart hook: a short standing instruction so the board is used without the user asking for it.
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
s="$root/skills/status-board"
msg="The status-board plugin is installed. Show a job on its live board without waiting to be asked when it is a batch of 2 or more items that takes more than about a minute, or one task over about 1-2 minutes whose progress can be measured (the app or tool reports a percentage, or the total is known), or when the user asks for progress or status. Load the status-board:status-board skill first; then, before waiting on the job, tell the user in plain text how to watch it and how to stop it. Do not open a board for a single task with no measurable progress: say what is running and how to stop it, then report the result. Writer helpers: $s/scripts/sb-lib.sh (one-shot updates: $s/scripts/sb.sh). Viewer: $s/scripts/job-status.sh."
msg=${msg//\\/\\\\}; msg=${msg//\"/\\\"}
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
