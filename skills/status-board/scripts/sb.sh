#!/usr/bin/env bash
# status-board, one command per update: drive a board from outside a job script, e.g. with progress Claude reads
# through an app's own tools (an export percentage, an app's "time left") that no script on this machine can see.
#
#   sb.sh <state-dir> init "<title>" <item-count> [total-weight] ["<stop command>"]
#   sb.sh <state-dir> <command> [args...]    command = any sb-lib.sh helper without its sb_ prefix:
#         cols item start stage progress pct count cell ok warn fail skip state finish
#
# Examples:
#   SB_WATCH_PID=<pid of the app doing the work> sb.sh "$S" init "Export: final cut" 1 "<how to cancel it>"
#   sb.sh "$S" start 1 "final cut.mp4"; sb.sh "$S" stage encoding
#   sb.sh "$S" pct 26 21:00            # 26% and 21 minutes left, as the app reported them
#   sb.sh "$S" ok "1.2 GB"; sb.sh "$S" finish
#
# SB_WATCH_PID (on init): the board says NOT RUNNING when this process exits. Without it there is no process to
# watch, and health comes from fresh updates alone. SB_SLOW_AFTER / SB_STALL_AFTER (on init): set them above the
# interval between your updates, or the board will (rightly) call the job SLOW? / STALLED? between them.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sb-lib.sh" || exit 1
usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 2 ] || usage
st=$1; cmd=$2; shift 2
case "$cmd" in
  init)   SB_WATCH_PID=${SB_WATCH_PID:-none} sb_init "$st" "$@";;
  cols|item|start|stage|progress|pct|count|cell|ok|warn|fail|skip|state|finish)
          _sb_load "$st" || exit 1; "sb_$cmd" "$@";;
  *)      echo "sb.sh: unknown command: $cmd" >&2; usage;;
esac
