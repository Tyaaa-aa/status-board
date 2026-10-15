#!/usr/bin/env bash
# PostToolUse hook (Bash): when a status-board job has been started from this Claude session, show the user a
# one-time notice with the commands to watch it and stop it. Claude Code displays the notice itself, so it does not
# depend on Claude remembering to pass it on. Turn off with STATUS_BOARD_NOTICE=0.
input=$(head -c 65536); cat >/dev/null 2>&1
[ "${STATUS_BOARD_NOTICE:-1}" = 0 ] && exit 0
home="${STATUS_BOARD_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/status-board}"
reg="$home/jobs"; seen="$home/announced"
[ -f "$reg" ] || exit 0
sid=$(grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' <<<"$input" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
[ -n "$sid" ] || exit 0
touch "$seen" 2>/dev/null || exit 0

new_jobs() { awk -F'\t' -v s="$sid" 'FILENAME == ARGV[1] { seen[$0] = 1; next } $2 == s && !($3 in seen) { print $3 }' "$seen" "$reg"; }
new=$(new_jobs)
if [ -z "$new" ]; then
  # a job started in the background registers a moment after the command returns: wait briefly, but only then
  grep -q -E 'nohup|setsid|sb_init|sb-lib|run_in_background"[[:space:]]*:[[:space:]]*true|disown' <<<"$input" || exit 0
  for _ in 1 2 3 4 5 6; do sleep 0.25; new=$(new_jobs); [ -n "$new" ] && break; done
  [ -n "$new" ] || exit 0
fi

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
view="$root/skills/status-board/scripts/job-status.sh"
msg=
while IFS= read -r st; do
  [ -n "$st" ] || continue
  printf '%s\n' "$st" >> "$seen"
  h=$(bash "$view" --howto "$st" 2>/dev/null) || continue
  h=$(sed 's/^Running: /status-board · job started: /; s/^Watch:   /  Watch: /; s/^Stop:    /  Stop:  /' <<<"$h")
  msg+="${msg:+$'\n'}$h"
done <<<"$new"
[ -n "$msg" ] || exit 0
if [ "$(wc -l < "$seen")" -gt 1000 ]; then tail -n 500 "$seen" > "$seen.tmp" && mv -f "$seen.tmp" "$seen"; fi

esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }
ctx="The user has just been shown this status-board notice by the plugin:"$'\n'"$msg"
printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$(esc "$msg")" "$(esc "$ctx")"
