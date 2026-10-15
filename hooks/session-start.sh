#!/usr/bin/env bash
# SessionStart hook: a short standing instruction so the board is used without the user asking for it.
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
s="$root/skills/status-board"
msg="The status-board plugin is installed. Before starting any long-running or multi-item job (builds, test suites, file or data batches, downloads, conversions, migrations, anything likely to take more than about 30 seconds), load the status-board:status-board skill and show the job on its live board without waiting to be asked; tell the user how to watch it and how to stop it. Writer helpers: $s/scripts/sb-lib.sh. Viewer: $s/scripts/job-status.sh."
msg=${msg//\\/\\\\}; msg=${msg//\"/\\\"}
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$msg"
