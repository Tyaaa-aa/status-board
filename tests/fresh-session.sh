#!/usr/bin/env bash
# Behaviour test: does a fresh Claude Code session use the board for a batch job without being asked?
# Runs one batch-job prompt (that never mentions status or progress) in fresh `claude -p` sessions,
# in empty temp folders, and checks the transcripts:
#   A = skill only (installed plugin switched off for the session, a hook-less copy loaded instead)
#   B = the installed plugin as users get it (skill + SessionStart hook)
# Usage: tests/fresh-session.sh [A|B|AB] [seconds-to-wait-per-file]      (needs a logged-in `claude` CLI; costs tokens)
#   HIDE_GLOBAL_CLAUDE_MD=1  temporarily move ~/.claude/CLAUDE.md aside, so personal rules cannot decide the result.
#                            It is restored on exit, and also at the start of the next run if a crash left it hidden.
here="$(cd "$(dirname "$0")/.." && pwd)"
runs=${1:-AB}; wait_s=${2:-30}
G="$HOME/.claude/CLAUDE.md"; H="$HOME/.claude/CLAUDE.md.hidden-for-test"
if [ -e "$H" ]; then
  if [ -e "$G" ]; then echo "both $G and $H exist; resolve by hand" >&2; exit 1; fi
  mv "$H" "$G" && echo "restored $G left hidden by an interrupted run"
fi
claude auth status 2>/dev/null | grep -q '"loggedIn": true' || { echo "claude CLI is not logged in: run 'claude auth login'" >&2; exit 1; }

OUT="${TMPDIR:-/tmp}/sb-fresh-session"; rm -rf "$OUT"; mkdir -p "$OUT"
source "$here/skills/status-board/scripts/sb-lib.sh"
SB_STALL_AFTER=600
sb_init "$OUT/state" "Fresh-session test: is the board used unasked?" 2 "kill $$"
sb_cols "Run" "Setup" "Skill loaded" "Board used" "Told user watch+stop"
sb_item 1 A "skill only, no hook" - - -
sb_item 2 B "plugin with hook" - - -
echo "board: $here/skills/status-board/scripts/job-status.sh $OUT/state"

if [ -n "${HIDE_GLOBAL_CLAUDE_MD:-}" ] && [ -e "$G" ]; then
  mv "$G" "$H" || exit 1
  trap 'mv "$H" "$G"' EXIT INT TERM HUP
fi

SKILLONLY=$(mktemp -d); cp -r "$here/.claude-plugin" "$here/skills" "$SKILLONLY/"
PROMPT="Compress each .txt file in this folder with gzip -k, one file at a time, and wait $wait_s seconds after each file (in real use each one takes several minutes). Tell me when it is done."

judge() {  # transcript.jsonl -> skill<TAB>board<TAB>told
  python3 - "$1" <<'PY'
import json, sys
skill = board = False; texts = []
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except ValueError: continue
    if o.get("type") != "assistant": continue
    for c in o["message"]["content"]:
        if c.get("type") == "text": texts.append(c["text"])
        if c.get("type") == "tool_use":
            inp = json.dumps(c.get("input", {}))
            if c["name"] == "Skill" and "status-board" in inp: skill = True
            if c["name"] in ("Bash", "Write", "Edit") and ("sb_init" in inp or "sb-lib.sh" in inp): board = True
t = "\n".join(texts)
watch = "job-status" in t
stop = any(w in t for w in ("kill ", "pkill", "Stop:", "stop it", "To stop", "to stop"))
print("yes" if skill else "no", "yes" if board else "no",
      "yes" if watch and stop else "watch only" if watch else "stop only" if stop else "no", sep="\t")
PY
}
run() {  # idx label extra-args...
  local i=$1 label=$2 W s b t; shift 2
  W=$(mktemp -d); for k in 1 2 3 4 5 6; do head -c 100000 /dev/urandom | base64 > "$W/data$k.txt"; done
  sb_start "$i" "$label"; sb_stage "claude -p session"
  ( cd "$W" && sb_track 80 -- timeout 1200 claude -p "$PROMPT" --output-format stream-json --verbose \
      --allowedTools "Bash Skill Read Write Edit" "$@" ) > /dev/null
  cp "$SB_STATE/output.log" "$OUT/$label.jsonl"; : > "$SB_STATE/output.log"
  IFS=$'\t' read -r s b t < <(judge "$OUT/$label.jsonl")
  sb_cell "$i" 3 "$s"; sb_cell "$i" 4 "$b"; sb_cell "$i" 5 "$t"; sb_ok
}
case "$runs" in *A*) run 1 A --settings '{"enabledPlugins":{"status-board@status-board":false}}' --plugin-dir "$SKILLONLY";; *) sb_skip 1 "not run";; esac
case "$runs" in *B*) run 2 B;; *) sb_skip 2 "not run";; esac
sb_finish
echo "transcripts in $OUT"
