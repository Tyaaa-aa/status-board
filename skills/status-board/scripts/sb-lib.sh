#!/usr/bin/env bash
# status-board writer helpers. Source them from a bash job script:
#
#   source <skill-dir>/scripts/sb-lib.sh
#   sb_init     <state-dir> "<title>" <item-count> [total-weight] ["<stop command>"]   (weight may be left out)
#   sb_cols     "Name" "@Group" "Size" ...     pick the table columns for THIS job ('@' = coloured tag column)
#   sb_item     <idx> "cell" "cell" ...        register a row as queued; call once per item, up front
#   sb_start    <idx> "<label>" [weight]       the item starts (weight defaults to 1)
#   sb_stage    "<stage>"                      what the current item is doing now
#   sb_progress <done-weight> ["<rate>"]       progress inside the current item; rate is free text ("12 MB/s")
#   sb_track    <expected-lines> -- cmd ...    run cmd, count its output lines as progress, return its exit code
#   sb_cell     <idx> <column-number> "value"  change one cell (1-based) at any time
#   sb_ok       ["<note>"]                     the current item finished OK
#   sb_warn     "<note>"                       the current item finished, with a warning
#   sb_fail     ["<reason>"]                   the current item failed
#   sb_skip     <idx> ["<note>"] [weight]      an item that needs no work (counts as done)
#   sb_state    <idx> <queued|run|done|warn|fail|skip> ["<detail>"]   low-level row state (parallel jobs)
#   sb_finish                                  the whole job is done (call it last, not from an EXIT trap,
#                                              so a crash shows as NOT RUNNING instead of FINISHED)
#
# Optional, set before sb_init: SB_SLOW_AFTER=15 SB_STALL_AFTER=60 (seconds without progress before the board
# says SLOW? / STALLED?). Raise them for jobs with long silent steps.
# Weights are any consistent unit (items, bytes, seconds of media, test cases...); progress % = weight done / total.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "sb-lib.sh: needs bash 4.2 or newer" >&2; return 1 2>/dev/null || exit 1
fi
declare -gA SB_RS=() SB_RC=()
declare -ga SB_ORDER=()
SB_US=$'\x1f'

_sb_clean() { SB_V=${1//[$'\t\n\r\x1f']/ }; }                       # values must stay on one line, one cell
_sb_put()   { printf '%s' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"; }   # atomic write
_sb_fmt()   { local s=$1; if ((s >= 3600)); then printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60)); else printf '%d:%02d' $((s/60)) $((s%60)); fi; }
_sb_add()   { awk -v a="$1" -v b="$2" 'BEGIN{ s = a + b; if (s == int(s)) printf "%d", s; else printf "%.4f", s }'; }

sb_init() {
  SB_STATE="${1:?sb_init: state dir}"; _sb_clean "${2:-job}"; SB_TITLE=$SB_V
  SB_TOTAL="${3:-0}"; SB_WTOTAL="${4:-}"; SB_PID=${BASHPID:-$$}
  local stop="${5:-}"
  # forgiving: a non-numeric 4th argument is the stop command (total weight left out)
  if [ -n "$SB_WTOTAL" ] && ! [[ $SB_WTOTAL =~ ^[0-9]+([.][0-9]+)?$ ]]; then [ -z "$stop" ] && stop=$SB_WTOTAL; SB_WTOTAL=; fi
  [ -z "$SB_WTOTAL" ] && SB_WTOTAL=$SB_TOTAL
  _sb_clean "${stop:-kill $SB_PID}"; SB_STOP=$SB_V
  SB_DONE=0; SB_FAILED=0; SB_WARNED=0; SB_SKIPPED=0; SB_WDONE=0; SB_LAST=; SB_STARTED=$(date +%s)
  SB_IDX=; SB_LABEL=; SB_W=0; SB_T0=0; SB_STAGE=; SB_COLUMNS=; SB_FLUSHED=-1
  SB_RS=(); SB_RC=(); SB_ORDER=()
  mkdir -p "$SB_STATE" || return 1
  _sb_register
  rm -f "$SB_STATE/items.tsv" "$SB_STATE/output.log"
  echo "$SB_PID" > "$SB_STATE/job.pid"; _sb_put "$SB_STATE/progress" ""; : > "$SB_STATE/job.log"
  _sb_current; _sb_summary 0
}
_sb_register() {  # list the job so the plugin can tell the user (in the Claude session that started it) where it is
  local home="${STATUS_BOARD_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/status-board}" abs
  abs=$(cd "$SB_STATE" && pwd) || return 0
  mkdir -p "$home" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$(date +%s)" "${CLAUDE_CODE_SESSION_ID:-}" "$abs" >> "$home/jobs" 2>/dev/null || return 0
  if [ "$(wc -l < "$home/jobs")" -gt 1000 ]; then tail -n 500 "$home/jobs" > "$home/jobs.tmp" && mv -f "$home/jobs.tmp" "$home/jobs"; fi
}
_sb_summary() {
  _sb_put "$SB_STATE/summary.env" "TITLE=$SB_TITLE
TOTAL=$SB_TOTAL
DONE=$SB_DONE
FAILED=$SB_FAILED
WARNED=$SB_WARNED
SKIPPED=$SB_SKIPPED
WEIGHT_TOTAL=$SB_WTOTAL
WEIGHT_DONE=$SB_WDONE
STARTED=$SB_STARTED
FINISHED=${1:-0}
LAST=$SB_LAST
STOP=$SB_STOP
SLOW_AFTER=${SB_SLOW_AFTER:-15}
STALL_AFTER=${SB_STALL_AFTER:-60}
"
}
_sb_current() {
  if [ -n "$SB_LABEL" ]; then
    _sb_put "$SB_STATE/current.env" "IDX=$SB_IDX
NAME=$SB_LABEL
WEIGHT=$SB_W
STAGE=$SB_STAGE
ITEM_START=$SB_T0
"
  else _sb_put "$SB_STATE/current.env" ""; fi
}
_sb_flush() {  # rewrite items.tsv; big tables (>200 rows) at most once per second unless forced
  [ -n "$SB_COLUMNS" ] || return 0
  [ "${1:-}" != force ] && ((${#SB_ORDER[@]} > 200)) && [ "$SB_FLUSHED" = "$SECONDS" ] && return 0
  SB_FLUSHED=$SECONDS
  local i out="#COLUMNS	$SB_COLUMNS"$'\n'
  for i in "${SB_ORDER[@]}"; do out+="$i	${SB_RS[$i]}	${SB_RC[$i]//$SB_US/	}"$'\n'; done
  _sb_put "$SB_STATE/items.tsv" "$out"
}

sb_cols() { local a=() v; for v in "$@"; do _sb_clean "$v"; a+=("$SB_V"); done
            local IFS=$'\t'; SB_COLUMNS="${a[*]}"; _sb_flush force; }
sb_item() { local i="$1" a=() v; shift; _sb_clean "$i"; i=$SB_V
            for v in "$@"; do _sb_clean "$v"; a+=("$SB_V"); done
            [ -z "${SB_RS[$i]+x}" ] && SB_ORDER+=("$i")
            SB_RS[$i]=queued; local IFS=$SB_US; SB_RC[$i]="${a[*]}"; _sb_flush; }
sb_cell() { local i="$1" c=$(( $2 - 1 )) a=() k; ((c >= 0)) || return 1
            [ -z "${SB_RS[$i]+x}" ] && { SB_ORDER+=("$i"); SB_RS[$i]=queued; }
            IFS=$SB_US read -ra a <<<"${SB_RC[$i]:-}"
            for ((k = 0; k < c; k++)); do a[k]=${a[k]-}; done
            _sb_clean "$3"; a[c]=$SB_V; local IFS=$SB_US; SB_RC[$i]="${a[*]}"; _sb_flush force; }
sb_state() { [ -z "${SB_RS[$1]+x}" ] && { SB_ORDER+=("$1"); SB_RC[$1]=; }
             _sb_clean "${3:-}"; SB_RS[$1]="$2${SB_V:+:$SB_V}"; _sb_flush force; }

sb_start() {
  SB_IDX="$1"; _sb_clean "${2:-item $1}"; SB_LABEL=$SB_V; SB_W="${3:-1}"; SB_T0=$(date +%s); SB_STAGE=
  [ -n "$SB_COLUMNS" ] && sb_state "$SB_IDX" run
  _sb_put "$SB_STATE/progress" ""; _sb_current
}
sb_stage() {
  _sb_clean "$1"; SB_STAGE=$SB_V
  [ -n "$SB_COLUMNS" ] && [ -n "$SB_IDX" ] && sb_state "$SB_IDX" run "$SB_STAGE"
  _sb_current
}
sb_progress() { _sb_clean "${2:-}"; _sb_put "$SB_STATE/progress" "done=${1:-0}
rate=$SB_V
"; }
sb_track() {
  local exp=${1:-100}; shift; [ "${1:-}" = -- ] && shift
  local n=0 last=-1 w=${SB_W:-1} out="$SB_STATE/output.log" l
  "$@" 2>&1 | while IFS= read -r l || [ -n "$l" ]; do
    printf '%s\n' "$l" >> "$out"; n=$((n + 1))
    if [ "$SECONDS" != "$last" ]; then last=$SECONDS
      sb_progress "$(awk -v n="$n" -v e="$exp" -v w="$w" 'BEGIN{ f = (e > 0) ? n/e : 0; if (f > 0.99) f = 0.99; printf "%.4f", f*w }')"
    fi
  done
  return "${PIPESTATUS[0]}"
}

_sb_end() {  # <row-state> <note> <label-suffix>
  local took=0; ((SB_T0 > 0)) && took=$(( $(date +%s) - SB_T0 ))
  _sb_clean "${2:-}"; local note=$SB_V
  SB_LAST="$SB_LABEL${3:+ $3}${note:+: $note} ($(_sb_fmt "$took"))"
  SB_WDONE=$(_sb_add "$SB_WDONE" "${SB_W:-0}")
  echo "$(date '+%F %T') ${1^^} $SB_IDX/$SB_TOTAL $SB_LABEL${note:+: $note} ($(_sb_fmt "$took"))" >> "$SB_STATE/job.log"
  [ -n "$SB_COLUMNS" ] && [ -n "$SB_IDX" ] && sb_state "$SB_IDX" "$1" "$note"
  SB_IDX=; SB_LABEL=; SB_W=0; SB_STAGE=
  _sb_put "$SB_STATE/progress" ""; _sb_current; _sb_summary 0
}
sb_ok()   { SB_DONE=$((SB_DONE + 1)); _sb_end done "${1:-}"; }
sb_warn() { SB_DONE=$((SB_DONE + 1)); SB_WARNED=$((SB_WARNED + 1)); _sb_end warn "${1:-warning}"; }
sb_fail() { SB_FAILED=$((SB_FAILED + 1)); _sb_end fail "${1:-}" FAILED; }
sb_skip() {
  SB_DONE=$((SB_DONE + 1)); SB_SKIPPED=$((SB_SKIPPED + 1)); SB_WDONE=$(_sb_add "$SB_WDONE" "${3:-1}")
  [ -n "$SB_COLUMNS" ] && sb_state "$1" skip "${2:-}"
  _sb_summary 0
}
sb_finish() {
  SB_IDX=; SB_LABEL=; _sb_current; _sb_flush force; _sb_summary 1
  echo "$(date '+%F %T') FINISHED done=$SB_DONE failed=$SB_FAILED total=$SB_TOTAL" >> "$SB_STATE/job.log"
}
