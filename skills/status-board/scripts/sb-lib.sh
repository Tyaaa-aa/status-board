#!/usr/bin/env bash
# status-board writer helpers. Source them from a bash job script:
#
#   source <skill-dir>/scripts/sb-lib.sh
#   sb_init     <state-dir> "<title>" <item-count> [total-weight] ["<stop command>"]   (weight may be left out)
#   sb_cols     "Name" "@Group" "Size" ...     pick the table columns for THIS job ('@' = coloured tag column)
#   sb_item     <idx> "cell" "cell" ...        register a row as queued; call once per item, up front
#   sb_start    <idx> "<label>" [weight]       the item starts (weight defaults to 1)
#   sb_start    <idx> "<label>" ? [weight]     ...and its progress cannot be measured (no known total): the board
#                                              shows "no % available" instead of a bar stuck at 0%
#   sb_stage    "<stage>"                      what the current item is doing now
#   sb_progress <done-weight> ["<rate>"]       progress inside the current item; rate is free text ("12 MB/s")
#   sb_pct      <percent> [eta]                progress as the tool/app itself reports it (eta: seconds or m:ss)
#   sb_count    "<text>"                       what has happened so far when there is no total ("54 MB written")
#   sb_watch    <seconds>                      readings come from someone checking every <seconds> (e.g. Claude
#                                              polling an app): health then follows that schedule
#   sb_unwatched                               nobody is checking any more: the board says NOT WATCHED (grey)
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
# From outside a job script (one command per update, e.g. progress Claude reads through an app's tools): sb.sh.
#
# Optional, set before sb_init: SB_SLOW_AFTER=15 SB_STALL_AFTER=60 (seconds without progress before the board
# says NO PROGRESS in yellow / red). Raise them for jobs with long silent steps. SB_CHECK_EVERY=<seconds>: same
# as sb_watch, from the start. SB_JOB_STARTED=<epoch>: the board is attached to a job that was already running
# and started then (elapsed and ETAs count from it); SB_JOB_STARTED=unknown: already running, start unknown (the
# board then says "watched for" and never extrapolates an ETA from a progress it did not see from the start).
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
  # SB_WATCH_PID: the process whose exit means "not running" (default: this job). 'none' = no process to watch.
  local pid=${SB_WATCH_PID:-$SB_PID}
  local stop="${5:-}"
  # forgiving: a non-numeric 4th argument is the stop command (total weight left out)
  if [ -n "$SB_WTOTAL" ] && ! [[ $SB_WTOTAL =~ ^[0-9]+([.][0-9]+)?$ ]]; then [ -z "$stop" ] && stop=$SB_WTOTAL; SB_WTOTAL=; fi
  # no total weight: every item counts as 1 overall, and sb_start's weight only scales progress inside the item
  SB_WEXPLICIT=1; [ -z "$SB_WTOTAL" ] && { SB_WTOTAL=$SB_TOTAL; SB_WEXPLICIT=0; }
  [ -z "$stop" ] && [ -z "${SB_WATCH_PID:-}" ] && stop="kill $SB_PID"   # never default to killing a watched process
  _sb_clean "$stop"; SB_STOP=$SB_V
  SB_DONE=0; SB_FAILED=0; SB_WARNED=0; SB_SKIPPED=0; SB_WDONE=0; SB_LAST=; SB_STARTED=$(date +%s); SB_ATT=0
  case "${SB_JOB_STARTED:-}" in
    '') ;; unknown) SB_ATT=2;;
    *) if [[ $SB_JOB_STARTED =~ ^[0-9]+$ ]] && ((SB_JOB_STARTED <= SB_STARTED)); then SB_STARTED=$SB_JOB_STARTED; SB_ATT=1
       else echo "sb_init: SB_JOB_STARTED must be an epoch time in the past, or 'unknown'" >&2; fi;;
  esac
  SB_IDX=; SB_LABEL=; SB_W=0; SB_WI=1; SB_M=1; SB_T0=0; SB_STAGE=; SB_COLUMNS=; SB_FLUSHED=-1
  SB_RS=(); SB_RC=(); SB_ORDER=(); SB_CHECK=${SB_CHECK_EVERY:-0}; SB_WATCHING=1; SB_FIN=0
  mkdir -p "$SB_STATE" || return 1
  _sb_register
  rm -f "$SB_STATE/items.tsv" "$SB_STATE/output.log"
  if [ "$pid" = none ]; then rm -f "$SB_STATE/job.pid"; else echo "$pid" > "$SB_STATE/job.pid"; fi; _sb_put "$SB_STATE/progress" ""; : > "$SB_STATE/job.log"
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
WEIGHT_EXPLICIT=$SB_WEXPLICIT
CHECK_EVERY=${SB_CHECK:-0}
ATTACHED=${SB_ATT:-0}
WATCHING=${SB_WATCHING:-1}
"
}
_sb_current() {
  if [ -n "$SB_LABEL" ]; then
    _sb_put "$SB_STATE/current.env" "IDX=$SB_IDX
NAME=$SB_LABEL
WEIGHT=$SB_W
ITEM_WEIGHT=$SB_WI
MEASURABLE=$SB_M
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
  SB_IDX="$1"; _sb_clean "${2:-item $1}"; SB_LABEL=$SB_V; SB_M=1
  [ "${3:-}" = "?" ] && { SB_M=0; set -- "$1" "$2" "${4:-}"; }
  SB_WI="${3:-1}"; SB_W=$SB_WI; ((SB_WEXPLICIT)) || SB_W=1
  SB_T0=$(date +%s); SB_STAGE=
  # attached to a job already under way: its first item started when the job did (or at an unknown time)
  ((${SB_ATT:-0} > 0 && SB_DONE + SB_FAILED + SB_SKIPPED == 0)) && SB_T0=$SB_STARTED
  [ -n "$SB_COLUMNS" ] && sb_state "$SB_IDX" run
  _sb_put "$SB_STATE/progress" ""; _sb_current
}
sb_stage() {
  _sb_clean "$1"; SB_STAGE=$SB_V
  [ -n "$SB_COLUMNS" ] && [ -n "$SB_IDX" ] && sb_state "$SB_IDX" run "$SB_STAGE"
  _sb_current
}
sb_progress() {  # done is in the units of the weight given to sb_start
  local d=${1:-0}
  if ((! SB_WEXPLICIT)) && [ "${SB_WI:-1}" != 1 ]; then d=$(awk -v d="$d" -v w="$SB_WI" 'BEGIN{ if (w > 0) printf "%.4f", d/w; else print 0 }'); fi
  _sb_prog done "$d" rate "${2:-}"; }
sb_pct() {  # <percent> [eta]: a percentage (and ETA) reported by the tool doing the work; wins over sb_progress
  local p=${1:-} e=${2:-}
  [[ $p =~ ^[0-9]+([.][0-9]+)?%?$ ]] || { echo "sb_pct: not a percentage: $p" >&2; return 1; }
  if [ -n "$e" ]; then e=$(_sb_secs "$e") || { echo "sb_pct: not a duration: $2" >&2; return 1; }; fi
  _sb_reading pct "${p%\%}" eta "$e"; }
sb_count() { _sb_reading count "${1:-}"; }   # free text for work without a total ("54 MB written", "1200 rows")
_sb_reading() {  # <key> <value> [...]: a reading; remember when it was taken and since when its value is unchanged
  local now old since; now=$(date +%s)
  old=$(sed -n "s/^$1=//p" "$SB_STATE/progress" 2>/dev/null | tail -n 1)
  since=$(sed -n 's/^since=//p' "$SB_STATE/progress" 2>/dev/null | tail -n 1)
  _sb_clean "$2"; { [ "$SB_V" != "$old" ] || [ -z "$since" ]; } && since=$now
  _sb_prog "$@" read "$now" since "$since"; }
sb_watch() {  # <seconds>: someone takes a reading about this often; health follows that schedule
  [[ ${1:-} =~ ^[0-9]+$ ]] && (($1 > 0)) || { echo "sb_watch: interval in seconds, e.g. 600" >&2; return 1; }
  SB_CHECK=$1; SB_WATCHING=1; _sb_summary "${SB_FIN:-0}"; }
sb_unwatched() { SB_WATCHING=0; _sb_summary "${SB_FIN:-0}"; }
_sb_secs() {  # "90", "90s", "1:30", "1:02:03", "39:53 left" -> seconds
  local t=${1//[!0-9:]/} a b c
  [[ $t =~ ^[0-9]+$ ]] && { echo "$((10#$t))"; return; }
  if [[ $t =~ ^([0-9]+):([0-9]{1,2})$ ]]; then echo $((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]})); return; fi
  if [[ $t =~ ^([0-9]+):([0-9]{1,2}):([0-9]{1,2})$ ]]; then a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]}
    echo $((10#$a * 3600 + 10#$b * 60 + 10#$c)); return; fi
  return 1; }
_sb_prog() {  # <key> <value> ...: change these keys of the progress file and keep the others (empty value = remove)
  local -A kv=(); local k v out= ks=(done pct eta count rate read since)
  if [ -f "$SB_STATE/progress" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do case "$k" in done|pct|eta|count|rate|read|since) kv[$k]=$v;; esac; done < "$SB_STATE/progress"
  fi
  while (($# >= 2)); do _sb_clean "$2"; kv[$1]=$SB_V; shift 2; done
  for k in "${ks[@]}"; do [ -n "${kv[$k]:-}" ] && out+="$k=${kv[$k]}"$'\n'; done
  _sb_put "$SB_STATE/progress" "$out"; }
sb_track() {
  local exp=${1:-100}; shift; [ "${1:-}" = -- ] && shift
  local n=0 last=-1 w=${SB_WI:-1} out="$SB_STATE/output.log" l
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
  SB_IDX=; SB_LABEL=; SB_W=0; SB_M=1; SB_STAGE=
  _sb_put "$SB_STATE/progress" ""; _sb_current; _sb_summary 0
}
sb_ok()   { SB_DONE=$((SB_DONE + 1)); _sb_end done "${1:-}"; }
sb_warn() { SB_DONE=$((SB_DONE + 1)); SB_WARNED=$((SB_WARNED + 1)); _sb_end warn "${1:-warning}"; }
sb_fail() { SB_FAILED=$((SB_FAILED + 1)); _sb_end fail "${1:-}" FAILED; }
sb_skip() {
  SB_DONE=$((SB_DONE + 1)); SB_SKIPPED=$((SB_SKIPPED + 1)); local w=1; ((SB_WEXPLICIT)) && w=${3:-1}; SB_WDONE=$(_sb_add "$SB_WDONE" "$w")
  [ -n "$SB_COLUMNS" ] && sb_state "$1" skip "${2:-}"
  _sb_summary 0
}
sb_finish() {
  SB_IDX=; SB_LABEL=; SB_FIN=1; _sb_current; _sb_flush force; _sb_summary 1
  echo "$(date '+%F %T') FINISHED done=$SB_DONE failed=$SB_FAILED total=$SB_TOTAL" >> "$SB_STATE/job.log"
}

_sb_load() {  # <state-dir>: rebuild the writer's variables from the state files (used by sb.sh, one command per call)
  SB_STATE="${1:?state dir}"; [ -f "$SB_STATE/summary.env" ] || { echo "status-board: no job in $SB_STATE (run init first)" >&2; return 1; }
  local k v line idx st rest
  SB_TITLE=job; SB_TOTAL=0; SB_WTOTAL=0; SB_DONE=0; SB_FAILED=0; SB_WARNED=0; SB_SKIPPED=0; SB_WDONE=0; SB_STARTED=0
  SB_LAST=; SB_STOP=; SB_WEXPLICIT=0; SB_IDX=; SB_LABEL=; SB_W=0; SB_WI=1; SB_M=1; SB_T0=0; SB_STAGE=
  SB_COLUMNS=; SB_FLUSHED=-1; SB_RS=(); SB_RC=(); SB_ORDER=(); SB_CHECK=0; SB_WATCHING=1; SB_FIN=0; SB_ATT=0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      TITLE) SB_TITLE=$v;; TOTAL) SB_TOTAL=$v;; WEIGHT_TOTAL) SB_WTOTAL=$v;; DONE) SB_DONE=$v;; FAILED) SB_FAILED=$v;;
      WARNED) SB_WARNED=$v;; SKIPPED) SB_SKIPPED=$v;; WEIGHT_DONE) SB_WDONE=$v;; STARTED) SB_STARTED=$v;; LAST) SB_LAST=$v;;
      STOP) SB_STOP=$v;; SLOW_AFTER) SB_SLOW_AFTER=$v;; STALL_AFTER) SB_STALL_AFTER=$v;; WEIGHT_EXPLICIT) SB_WEXPLICIT=$v;;
      CHECK_EVERY) SB_CHECK=$v;; WATCHING) SB_WATCHING=$v;; FINISHED) SB_FIN=$v;; ATTACHED) SB_ATT=$v;;
    esac
  done < "$SB_STATE/summary.env"
  if [ -f "$SB_STATE/current.env" ]; then
    while IFS='=' read -r k v || [ -n "$k" ]; do
      case "$k" in IDX) SB_IDX=$v;; NAME) SB_LABEL=$v;; WEIGHT) SB_W=$v;; ITEM_WEIGHT) SB_WI=$v;; MEASURABLE) SB_M=$v;;
        STAGE) SB_STAGE=$v;; ITEM_START) SB_T0=$v;; esac
    done < "$SB_STATE/current.env"
  fi
  if [ -f "$SB_STATE/items.tsv" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ $line == "#COLUMNS"$'\t'* ]]; then SB_COLUMNS=${line#"#COLUMNS"$'\t'}; continue; fi
      [[ -z $line || $line == '#'* ]] && continue
      IFS=$'\t' read -r idx st rest <<<"$line"
      SB_ORDER+=("$idx"); SB_RS[$idx]=$st; SB_RC[$idx]=${rest//$'\t'/$SB_US}
    done < "$SB_STATE/items.tsv"
  fi
}
