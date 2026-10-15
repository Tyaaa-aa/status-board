#!/usr/bin/env bash
# status-board viewer: a live, colour-coded board for any long-running job.
#
# Usage:  job-status.sh [--once|--howto] <state-dir> [refresh-seconds]
#   --once       print one frame without cursor control and exit (for scripts, tests and agents)
#   --howto      print a ready-to-paste "how to watch / how to stop" message for the user and exit
#   NO_COLOR=1   disable colour (symbols and layout still carry the meaning); colour is also off when the output
#                is not a terminal, unless FORCE_COLOR=1
# Keys:   ↑/↓ or k/j scroll · PgUp/PgDn page · g/G top/bottom · f follow the current item · q quit (job keeps running)
#
# The job writes plain files into <state-dir> (easiest via sb-lib.sh); the format is in ../STATUS-BOARD.md.
# Nothing here knows what kind of job it is: the job names its own table columns.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "status-board: needs bash 4 or newer (macOS: brew install bash)" >&2; exit 1
fi
once=0; howto=0
case "${1:-}" in --once) once=1; shift;; --howto) howto=1; shift;; esac
STATE="${1:?usage: job-status.sh [--once|--howto] <state-dir> [refresh-seconds]}"; EVERY="${2:-2}"
[[ $EVERY =~ ^[0-9]+([.][0-9]+)?$ ]] || EVERY=2
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;; *) { export LC_ALL=C.UTF-8; } 2>/dev/null;; esac

# ---- palette: a colour always means the same thing ----
if [ -n "${NO_COLOR:-}" ] || { [ ! -t 1 ] && [ -z "${FORCE_COLOR:-}" ]; }; then
  G=; GB=; C=; R=; Y=; D=; B=; N=; TAGS=("" "" "" "")
else
  G=$'\e[32m'      # done / healthy
  GB=$'\e[32;1m'   # finished
  C=$'\e[36;1m'    # active right now
  R=$'\e[31;1m'    # failed / stalled / not running
  Y=$'\e[33m'      # warning / slow
  D=$'\e[2m'       # queued, labels, secondary
  B=$'\e[1m'       # emphasis
  N=$'\e[0m'
  TAGS=($'\e[38;5;75m' $'\e[38;5;177m' $'\e[38;5;215m' $'\e[38;5;114m')   # tag column values, by first appearance
fi
US=$'\x1f'

fmt()   { local s=${1%.*}; [[ $s =~ ^[0-9]+$ ]] || s=0
          if ((s >= 3600)); then printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60)); else printf '%d:%02d' $((s/60)) $((s%60)); fi; }
# ago <seconds> -> "12s ago" / "4 min ago" / "1h 05m ago";  clock <epoch> -> "14:02"
ago()   { local s=${1:-0}; ((s < 60)) && { echo "${s}s ago"; return; }; ((s < 3600)) && { echo "$((s / 60)) min ago"; return; }
          printf '%dh %02dm ago\n' $((s / 3600)) $((s % 3600 / 60)); }
every() { local s=${1:-0}; ((s < 60)) && { echo "${s}s"; return; }; ((s < 3600)) && { echo "$((s / 60)) min"; return; }
          ((s % 3600)) && printf '%dh %02dm\n' $((s / 3600)) $((s % 3600 / 60)) || echo "$((s / 3600))h"; }
clock() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null || echo "?"; }
isnum() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# fit <text> <width> [l|r] -> FIT: padded, or cut with an ellipsis
fit()   { local s=$1 w=$2 n=${#1} sp; ((w < 1)) && { FIT=; return; }
          if ((n > w)); then s="${s:0:w-1}…"; n=$w; fi
          printf -v sp '%*s' $((w-n)) ''; if [ "${3:-l}" = r ]; then FIT="$sp$s"; else FIT="$s$sp"; fi; }
vis()   { local t=$1; while [[ $t == *$'\e['* ]]; do local a=${t%%$'\e['*} b=${t#*$'\e['}; t=$a${b#*m}; done; VIS_LEN=${#t}; }  # visible length
cut_to() { local s=$1 w=$2; ((${#s} > w)) && s="${s:0:w-1}…"; CUT=$s; }
# bar <pct> <width> <colour> -> BAR
bar()   { local p=$1 w=$2 f fs es; ((p < 0)) && p=0; ((p > 100)) && p=100; f=$((p*w/100))
          printf -v fs '%*s' "$f" ''; printf -v es '%*s' $((w-f)) ''; BAR="$3${fs// /█}$N$D${es// /░}$N"; }
# nobar <width> <text> -> BAR: dim dashes with the reason in the middle, for progress that has no percentage
nobar() { local w=$1 t=" $2 " l r s; ((${#t} + 4 > w)) && t=
          l=$(( (w - ${#t}) / 2 )); r=$((w - ${#t} - l)); printf -v s '%*s' "$l" ''; BAR="${s// /╌}$t"
          printf -v s '%*s' "$r" ''; BAR="$D$BAR${s// /╌}$N"; }
# secs <text> -> SECS: "90", "1:30", "1:02:03" -> seconds; returns 1 if it is not a duration
secs()  { local t=${1//[!0-9:]/}; SECS=
          if [[ $t =~ ^[0-9]+$ ]]; then SECS=$((10#$t))
          elif [[ $t =~ ^([0-9]+):([0-9]{1,2})$ ]]; then SECS=$((10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]}))
          elif [[ $t =~ ^([0-9]+):([0-9]{1,2}):([0-9]{1,2})$ ]]; then
            SECS=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
          else return 1; fi; }
# readkv <file>: KEY=value lines -> known variables only (never sourced, so nothing in the file is executed)
readkv() { local k v; [ -f "$1" ] || return 0
           while IFS='=' read -r k v || [ -n "$k" ]; do
             case "$k" in TITLE|TOTAL|DONE|FAILED|WARNED|SKIPPED|WEIGHT_TOTAL|WEIGHT_DONE|STARTED|FINISHED|LAST|STOP|\
SLOW_AFTER|STALL_AFTER|CHECK_EVERY|WATCHING|IDX|NAME|WEIGHT|STAGE|ITEM_START|MEASURABLE) printf -v "$k" '%s' "${v%$'\r'}";; esac
           done < "$1"; }

if ((howto)); then
  TITLE=; TOTAL=0; STOP=; readkv "$STATE/summary.env"
  self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  st=$(cd "$STATE" 2>/dev/null && pwd) || st=$STATE
  q() { printf '%q' "$1"; }
  echo "Running: ${TITLE:-job} (${TOTAL} items)"
  echo "Watch:   bash $(q "$self") $(q "$st")"
  pid=$(head -n 1 "$STATE/job.pid" 2>/dev/null)
  echo "Stop:    ${STOP:-${pid:+kill $pid}}"
  exit 0
fi

declare -A tagc=(); tagn=0
follow=1; off=0; avail=10
if ((once == 0)) && [ -t 1 ]; then
  printf '\033[?25l\033[2J'; trap 'printf "\033[?25h"' EXIT; trap 'exit 0' INT TERM
fi

while :; do
  TITLE=; TOTAL=0; DONE=0; FAILED=0; WARNED=0; SKIPPED=0; WEIGHT_TOTAL=0; WEIGHT_DONE=0; STARTED=0; FINISHED=0
  LAST=; STOP=; SLOW_AFTER=15; STALL_AFTER=60; CHECK_EVERY=0; WATCHING=1; IDX=; NAME=; WEIGHT=0; STAGE=; ITEM_START=0; MEASURABLE=1
  readkv "$STATE/summary.env"; readkv "$STATE/current.env"
  for v in TOTAL DONE FAILED WARNED SKIPPED STARTED FINISHED ITEM_START SLOW_AFTER STALL_AFTER CHECK_EVERY WATCHING; do
    [[ ${!v} =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
  for v in WEIGHT_TOTAL WEIGHT_DONE WEIGHT; do isnum "${!v}" || printf -v "$v" 0; done
  ((SLOW_AFTER > 0)) || SLOW_AFTER=15; ((STALL_AFTER > SLOW_AFTER)) || STALL_AFTER=$((SLOW_AFTER * 4))
  now=$(date +%s)

  COLS=; ROWS=
  if [ -t 1 ]; then COLS=$(tput cols 2>/dev/null); ROWS=$(tput lines 2>/dev/null); fi
  [[ $COLS =~ ^[0-9]+$ ]] || COLS=${COLUMNS:-100}; [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=${LINES:-40}
  [[ $COLS =~ ^[0-9]+$ ]] || COLS=100; [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=40
  W=$((COLS - 1)); ((W > 110)) && W=110; ((W < 30)) && W=30
  printf -v RULE '%*s' "$W" ''; RULE="$D${RULE// /─}$N"

  L=()
  if [ ! -f "$STATE/summary.env" ]; then
    L+=("${B}status-board${N}" "$RULE" "${D}Waiting for job state in${N} $STATE ${D}(no summary.env yet)${N}")
  else
    # ---- progress, freshness, liveness ----
    done_w=0; rate=; out_line=; have_done=0; pct_r=; eta_r=-1; count=; read_r=; since_r=
    if [ -f "$STATE/progress" ]; then
      blk=$(tail -n 20 "$STATE/progress")
      pa=$((now - $(mtime "$STATE/progress"))); ((pa < 0)) && pa=0
      p=$(sed -n 's/^pct=//p' <<<"$blk" | tail -n 1); p=${p%\%}
      isnum "$p" && pct_r=$(awk -v p="$p" 'BEGIN{ if (p > 100) p = 100; printf "%d", p }')
      e=$(sed -n 's/^eta=//p' <<<"$blk" | tail -n 1)
      [ -n "$e" ] && secs "$e" && { eta_r=$((SECS - pa)); ((eta_r < 0)) && eta_r=0; }   # counts down between reports
      count=$(sed -n 's/^count=//p' <<<"$blk" | tail -n 1)
      read_r=$(sed -n 's/^read=//p' <<<"$blk" | tail -n 1); since_r=$(sed -n 's/^since=//p' <<<"$blk" | tail -n 1)
      dn=$(sed -n 's/^done=//p' <<<"$blk" | tail -n 1)
      if [ -z "$dn" ]; then   # tools that write ffmpeg-style -progress files
        us=$(sed -n 's/^out_time_us=//p' <<<"$blk" | tail -n 1); isnum "$us" && dn=$(awk -v u="$us" 'BEGIN{printf "%.3f", u/1e6}')
      fi
      isnum "$dn" && { done_w=$dn; have_done=1; }
      rate=$(sed -n 's/^rate=//p; s/^speed=//p' <<<"$blk" | tail -n 1); rate=${rate## }
      case "$rate" in ''|0|0x|0.0|0.0x|0.00x|N/A) rate=;; esac
    fi
    newest=0
    for f in progress current.env summary.env items.tsv output.log; do
      [ -e "$STATE/$f" ] && { t=$(mtime "$STATE/$f"); ((t > newest)) && newest=$t; }; done
    age=$((now - newest)); ((age < 0)) && age=0
    # no job.pid = no process to watch (e.g. a board driven by sb.sh); health then comes from fresh updates alone
    alive=1; [ -s "$STATE/job.pid" ] && { kill -0 "$(head -n 1 "$STATE/job.pid")" 2>/dev/null || alive=0; }
    [ -s "$STATE/output.log" ] && out_line=$(tail -n 1 "$STATE/output.log" | tr -d '\r' | tr -c '[:print:]' ' ')

    inflight=0; [ "$FINISHED" != 1 ] && [ -n "$NAME" ] && inflight=1
    el=0; ((STARTED > 0)) && el=$((now - STARTED)); ((el < 0)) && el=0
    iel=0; ((ITEM_START > 0)) && iel=$((now - ITEM_START)); ((iel < 0)) && iel=0
    # what is known about the current item: 2 = a percentage, 1 = nothing reported yet, 0 = cannot be measured
    known=2
    if ((inflight)) && [ -z "$pct_r" ]; then
      if [ "$MEASURABLE" = 0 ]; then known=0; elif ((have_done == 0)) || [ "$WEIGHT" = 0 ]; then known=1; fi
    fi
    single=0; ((TOTAL == 1)) && single=1
    read -r all_pct cur_pct all_eta cur_eta < <(awk -v wd="$WEIGHT_DONE" -v wt="$WEIGHT_TOTAL" -v cw="$WEIGHT" \
      -v cd="$done_w" -v dn="$DONE" -v fl="$FAILED" -v tot="$TOTAL" -v inf="$inflight" -v el="$el" -v iel="$iel" \
      -v pr="${pct_r:--1}" 'BEGIN{
        if (!inf) cd = 0; if (cw > 0 && cd > cw) cd = cw
        if (inf && pr >= 0) { ip = pr; cd = (cw > 0 ? cw : 1) * pr / 100 } else ip = (inf && cw > 0) ? 100*cd/cw : 0
        if (wt > 0) ap = 100*(wd+cd)/wt; else if (tot > 0) ap = 100*(dn+fl)/tot; else ap = 0
        if (ap > 100) ap = 100
        ae = (ap >= 1 && ap < 100) ? el*(100-ap)/ap : 0
        ie = (ip >= 1 && ip < 100) ? iel*(100-ip)/ip : 0
        printf "%d %d %d %d\n", ap, ip, ae, ie }')
    [ "$FINISHED" = 1 ] && all_pct=100
    ((inflight && eta_r >= 0)) && cur_eta=$eta_r            # the tool's own ETA beats extrapolation
    ((single && inflight)) && { all_pct=$cur_pct; all_eta=$cur_eta; }
    # why there is no number, in plain words (never "calculating" when nothing is being calculated)
    case "$known" in 0) why="no % available";; 1) why="no % reported yet";; *) why=; esac

    # health: full sentence if it fits, else the short form. Every state is something the board actually knows.
    nw=0
    if   [ "$FINISHED" = 1 ]; then
      if ((FAILED > 0)); then health="${GB}● FINISHED${N} - ${R}${FAILED} failed${N}"; hs=$health
      else health="${GB}● FINISHED${N}"; hs=$health; fi; bc=$GB
    elif ((alive == 0)); then
      health="${R}● NOT RUNNING${N} - the job process has exited without finishing"; hs="${R}● NOT RUNNING${N}"; bc=$R
    elif ((CHECK_EVERY > 0)); then
      # fed by readings (someone checks every CHECK_EVERY s): silence between readings is the schedule, not the job
      rd=$newest; [[ $read_r =~ ^[0-9]+$ ]] && rd=$read_r
      rage=$((now - rd)); ((rage < 0)) && rage=0
      stuck=0; ((inflight)) && [[ $since_r =~ ^[0-9]+$ ]] && ((rd > since_r)) && stuck=$((rd - since_r))
      if ((WATCHING == 0)); then
        nw=1; health="${D}● NOT WATCHED - Claude stopped checking; last reading $(ago "$rage"). Ask Claude for an update${N}"
      elif ((rage > CHECK_EVERY + CHECK_EVERY / 4 + 90)); then   # a check is overdue (allows for late timers)
        nw=1; health="${D}● NOT WATCHED - no reading for $(fmt "$rage") (due every $(every "$CHECK_EVERY")). Ask Claude for an update${N}"
      fi
      if ((nw)); then hs="${D}● NOT WATCHED $(ago "$rage")${N}"; bc=$D
      elif ((stuck >= SLOW_AFTER)); then
        c=$Y; ((stuck >= STALL_AFTER)) && c=$R
        health="${c}● NO PROGRESS for $(fmt "$stuck")${N} - same reading since $(clock "$since_r")"; hs="${c}● NO PROGRESS $(fmt "$stuck")${N}"; bc=$c
      else
        nx=$((rd + CHECK_EVERY)); if ((nx > now)); then nt="next check ~$(clock "$nx")"; else nt="next check due now"; fi
        health="${G}● OK${N} - last reading $(ago "$rage") ${D}($nt)${N}"; hs="${G}● OK${N} ${D}$(ago "$rage")${N}"; bc=$G
      fi
    elif ((age <= SLOW_AFTER)); then
      health="${G}● OK${N} - progressing ${D}(last update ${age}s ago)${N}"; hs="${G}● OK${N} ${D}${age}s ago${N}"; bc=$G
    else
      # no progress reported: say how long, not what it means (a long silent step is not a hang)
      c=$Y; ((age > STALL_AFTER)) && c=$R; a=$(fmt "$age")
      health="${c}● NO PROGRESS for $a${N}"; hs=$health; bc=$c
    fi
    if ((nw && inflight)); then   # a stale reading is shown as a reading, with its time; never as live
      if ((eta_r >= 0)); then cur_eta=0; eta_nw="around $(clock $((now + eta_r))) (app's estimate at $(clock "$rd"))"; eta_nws="~$(clock $((now + eta_r)))"
      else cur_eta=0; eta_nw="unknown - not watched"; eta_nws=unknown; fi
      ((single)) && all_eta=0
    fi
    vis "$health"; ((9 + VIS_LEN > W)) && health=$hs

    # ---- fixed header ----
    cut_to "${TITLE:-job}" "$W"; L+=("$B$CUT$N" "$RULE")
    # optional parts after a progress bar, most useful first; a part is dropped if it would not fit on the line
    # eta_line <text> <short text>: the elapsed/ETA line, with the short wording when the long one does not fit
    eta_line() { local t=$1 el_t; el_t=$(fmt "$el"); ((9 + 8 + ${#el_t} + 7 + ${#t} > W)) && t=$2
                 L+=("         ${D}elapsed${N} $el_t   ${D}ETA${N} $B$t$N"); }
    extras() { local k; for k in "${!extra[@]}"; do
                 ((used + 3 + ${#plain[k]} > W)) && continue
                 ln+="   ${extra[k]}"; used=$((used + 3 + ${#plain[k]})); done; }
    if ((single)); then
      # one item: one progress line, no repeated bar, no one-row table (its cells become the Details line)
      BW=$((W - 9 - 2 - 5)); ((BW > 30)) && BW=30; ((BW < 5)) && BW=5
      if ((inflight)); then
        pre="NOW      "; room=$((W - ${#pre} - 4))
        cut_to "$NAME" $(( room * 2 / 3 > 8 ? room * 2 / 3 : 8 )); nm=$CUT
        sr=$((room - ${#nm})); ((sr > 30)) && sr=30; ((sr < 3)) && sr=3; cut_to "${STAGE:-running}" "$sr"
        L+=("${D}NOW${N}      $C$nm$N  ${D}[$CUT]${N}")
      fi
      if ((inflight && known < 2)); then nobar "$BW" "$why"; ln="${D}Progress${N} [$BAR]"; used=$((9 + BW + 2))
      else bar "$all_pct" "$BW" "$bc"; ln="${D}Progress${N} [$BAR] $B$(printf '%3d' "$all_pct")%$N"; used=$((9 + BW + 2 + 5)); fi
      extra=(); plain=()
      if ((inflight)); then
        ((nw)) && { t="at $(clock "$rd")"; extra+=("$D$t$N"); plain+=("$t"); }
        [ -n "$count" ] && { cut_to "$count" 24; extra+=("$B$CUT$N"); plain+=("$CUT"); }
        [ -n "$rate" ] && { cut_to "$rate" 16; extra+=("${D}rate${N} $B$CUT$N"); plain+=("rate $CUT"); }
      fi
      extras; L+=("$ln")
      if [ "$FINISHED" = 1 ] || ((!inflight && DONE + FAILED > 0)); then eta_line done done
      elif ((!inflight)); then eta_line "not started" "not started"
      elif ((nw)); then eta_line "$eta_nw" "$eta_nws"
      elif ((cur_eta > 0 || eta_r == 0)); then e="~$(fmt "$cur_eta")"; eta_line "$e" "$e"
      elif ((known < 2)); then eta_line "unknown - $why" unknown
      else eta_line "not enough progress yet" "too early"; fi
      # Details: the item's table cells, minus placeholders and the item name already shown above
      if [ -f "$STATE/items.tsv" ]; then
        hd=(); cl=(); det=; detp=
        while IFS= read -r line || [ -n "$line" ]; do
          line=${line%$'\r'}; line=${line//$'\t'/$US}
          if [[ $line == "#COLUMNS$US"* ]]; then IFS=$US read -ra hd <<<"${line#"#COLUMNS$US"}"; continue; fi
          [[ -z $line || $line == '#'* ]] && continue
          IFS=$US read -r _ _ f_rest <<<"$line"; IFS=$US read -ra cl <<<"$f_rest"; break
        done < "$STATE/items.tsv"
        for k in "${!cl[@]}"; do
          v=${cl[k]}; [[ -z $v || $v == - || $v == "$NAME" ]] && continue
          h=${hd[k]:-}; h=${h#@}
          detp+="${detp:+ · }${h:+$h }$v"; det+="${det:+$D · $N}${h:+$D$h$N }$v"
        done
        if [ -n "$detp" ]; then
          if ((${#detp} > W - 9)); then cut_to "$detp" $((W - 9)); det=$CUT; fi
          L+=("${D}Details${N}  $det")
        fi
      fi
      [ "$FINISHED" != 1 ] && [ -n "$out_line" ] && { cut_to "$out_line" $((W - 9)); L+=("${D}Output   $CUT$N"); }
    else
    fails=""; fp=""; ((FAILED > 0)) && { fails=", ${R}${FAILED} failed${N}"; fp=", $FAILED failed"; }
    warns=""; wp=""; ((WARNED > 0)) && { warns=", ${Y}${WARNED} warned${N}"; wp=", $WARNED warned"; }
    tail_p="$DONE/$TOTAL done$fp$wp"
    if ((9 + 2 + 5 + 3 + ${#tail_p} + 5 > W)); then fails=""; warns=""; tail_p="$DONE/$TOTAL"; ((FAILED)) && { fails=" ${R}✖$FAILED${N}"; tail_p+=" ✖$FAILED"; }; fi
    OBW=$((W - 9 - 2 - 5 - 3 - ${#tail_p})); ((OBW > 30)) && OBW=30; ((OBW < 5)) && OBW=5; BW=$OBW
    bar "$all_pct" "$OBW" "$bc"
    if [[ $tail_p == *done* ]]; then dt="$DONE/$TOTAL done"; else dt="$DONE/$TOTAL"; fi
    printf -v ln '%sOverall%s  [%s] %s%3d%%%s   %s%s%s%s%s' "$D" "$N" "$BAR" "$B" "$all_pct" "$N" "$G" "$dt" "$N" "$fails" "$warns"
    L+=("$ln")
    if [ "$FINISHED" = 1 ]; then eta_line done done; elif ((all_eta > 0)); then e="~$(fmt "$all_eta")"; eta_line "$e" "$e"
    elif ((DONE + FAILED + SKIPPED == 0 && known < 2)); then eta_line "unknown until the first item finishes" "unknown yet"
    else eta_line "not enough progress yet" "too early"; fi
    if [ "$FINISHED" != 1 ]; then
      if ((inflight)); then
        pre="NOW ($IDX/$TOTAL)  "; room=$((W - ${#pre} - 4))
        cut_to "$NAME" $(( room * 2 / 3 > 8 ? room * 2 / 3 : 8 )); nm=$CUT
        sr=$((room - ${#nm})); ((sr > 30)) && sr=30; ((sr < 3)) && sr=3; cut_to "${STAGE:-running}" "$sr"
        L+=("${D}NOW${N} ${D}(${IDX}/${TOTAL})${N}  $C$nm$N  ${D}[$CUT]${N}")
        if ((known < 2)); then nobar "$BW" "$why"; ln="         [$BAR]"; used=$((9 + BW + 2))
        else bar "$cur_pct" "$BW" "$C"; ln="         [$BAR] $B$(printf '%3d' "$cur_pct")%$N"; used=$((9 + BW + 2 + 5)); fi
        extra=(); plain=()
        [ -n "$count" ] && { cut_to "$count" 24; extra+=("$B$CUT$N"); plain+=("$CUT"); }
        [ -n "$rate" ] && { cut_to "$rate" 16; extra+=("${D}rate${N} $B$CUT$N"); plain+=("rate $CUT"); }
        ((cur_eta > 0)) && { e=$(fmt "$cur_eta"); extra+=("${D}item ETA${N} ~$e"); plain+=("item ETA ~$e"); }
        e=$(fmt "$iel"); extra+=("${D}running${N} $e"); plain+=("running $e")
        extras; L+=("$ln")
      else
        L+=("${D}NOW      between items${N}")
      fi
      [ -n "$out_line" ] && { cut_to "$out_line" $((W - 9)); L+=("${D}Output   $CUT$N"); }
    fi
    fi
    L+=("${D}Health${N}   $health")
    [ -n "$LAST" ] && { cut_to "$LAST" $((W - 9)); L+=("${D}Last${N}     $CUT"); }
    [ -n "$STOP" ] && [ "$FINISHED" != 1 ] && { cut_to "$STOP" $((W - 9)); L+=("${D}Stop${N}     $D$CUT$N"); }

    # ---- item table: columns come from the job ----
    cols=(); R_idx=(); R_st=(); R_det=(); CELL=(); nrows=0; ncols=0; curpos=-1
    if ((single == 0)) && [ -f "$STATE/items.tsv" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}; line=${line//$'\t'/$US}
        if [[ $line == "#COLUMNS$US"* ]]; then IFS=$US read -ra cols <<<"${line#"#COLUMNS$US"}"; continue; fi
        [[ -z $line || $line == '#'* ]] && continue
        IFS=$US read -r f_idx f_st f_rest <<<"$line"
        case "${f_st%%:*}" in
          run|running) s=run;; done|ok) s=done;; fail|failed|error) s=fail;; warn|warning) s=warn;;
          skip|skipped) s=skip;; *) s=queued;; esac
        R_idx+=("$f_idx"); R_st+=("$s"); [[ $f_st == *:* ]] && R_det+=("${f_st#*:}") || R_det+=("")
        IFS=$US read -ra cells <<<"$f_rest"
        ((${#cells[@]} > ncols)) && ncols=${#cells[@]}
        for ((c = 0; c < ${#cells[@]}; c++)); do CELL[nrows*64+c]=${cells[c]}; done
        [ "$s" = run ] && ((curpos < 0)) && curpos=$nrows
        nrows=$((nrows + 1))
      done < "$STATE/items.tsv"
    fi
    ((${#cols[@]} > ncols)) && ncols=${#cols[@]}; ((ncols > 64)) && ncols=64

    if ((nrows > 0)); then
      # status text per row (needed for its width)
      ST=(); stw=6
      for ((r = 0; r < nrows; r++)); do
        d=${R_det[r]}
        case "${R_st[r]}" in
          done) t="✔ ${d:-done}";; fail) t="✖ ${d:-failed}";; warn) t="! ${d:-warning}";; skip) t="– ${d:-skipped}";;
          run)  t="▶ ${d:-running}"
                if ((inflight && known == 2)) && [ "${R_idx[r]}" = "$IDX" ] && [[ $d != *%* ]]; then t+=" ${cur_pct}%"; fi;;
          *)    t="· ${d:-queued}";;
        esac
        ST[r]=$t; ((${#t} > stw)) && stw=${#t}
      done
      ((stw > 30)) && stw=30
      # columns: name, width, alignment, tag, visibility (decided from the data)
      HD=(); CW=(); RA=(); TG=(); VIS=()
      for ((c = 0; c < ncols; c++)); do
        nm=${cols[c]:-}; TG[c]=0; [[ $nm == @* ]] && { TG[c]=1; nm=${nm#@}; }; HD[c]=$nm
        w=${#nm}; same=1; first=${CELL[c]:-}; numeric=1; real=0
        for ((r = 0; r < nrows; r++)); do
          v=${CELL[r*64+c]:-}
          [ "$v" != "$first" ] && same=0
          if [ -n "$v" ] && [ "$v" != - ]; then real=1; [[ $v =~ ^[-~+]?[0-9][0-9.,:/]*[[:space:]]?[%A-Za-z/]{0,4}$ ]] || numeric=0; fi
          ((${#v} > w)) && w=${#v}
        done
        ((w > 40)) && w=40; ((w < 1)) && w=1
        CW[c]=$w; RA[c]=l; ((numeric && real)) && RA[c]=r
        VIS[c]=1; ((TG[c] && nrows > 1 && same && real)) && VIS[c]=0    # a tag column with one group says nothing
      done
      # shrink the widest visible columns until a row fits the terminal
      while :; do
        tot=$((1 + 3 + 2 + stw)); widest=-1
        for ((c = 0; c < ncols; c++)); do ((VIS[c])) || continue; tot=$((tot + CW[c] + 2))
          ((widest < 0 || CW[c] > CW[widest])) && widest=$c; done
        ((tot <= W || widest < 0 || CW[widest] <= 4)) && break
        CW[widest]=$((CW[widest] - 1))
      done
      ((tot > W)) && stw=$((stw - (tot - W))); ((stw < 6)) && stw=6

      fit '#' 3 r; hdr=" $FIT  "
      for ((c = 0; c < ncols; c++)); do ((VIS[c])) || continue; fit "${HD[c]}" "${CW[c]}" "${RA[c]}"; hdr+="$FIT  "; done
      hdr+="Status"

      hl=${#L[@]}
      avail=$((ROWS - hl - 7)); ((avail < 3)) && avail=3; ((avail > nrows)) && avail=$nrows
      ((once)) && avail=$nrows
      maxoff=$((nrows - avail)); ((maxoff < 0)) && maxoff=0
      ((follow && curpos >= 0)) && off=$((curpos - avail / 2))
      ((off > maxoff)) && off=$maxoff; ((off < 0)) && off=0

      L+=("" "$B$hdr$N" "$RULE")
      n_done=0; n_fail=0; n_run=0; n_q=0; n_warn=0; n_skip=0
      for ((r = 0; r < nrows; r++)); do
        case "${R_st[r]}" in done) n_done=$((n_done+1));; fail) n_fail=$((n_fail+1));; run) n_run=$((n_run+1));;
          warn) n_warn=$((n_warn+1));; skip) n_skip=$((n_skip+1));; *) n_q=$((n_q+1));; esac
        ((r < off || r >= off + avail)) && continue
        s=${R_st[r]}; dim=0; [[ $s == queued || $s == skip ]] && dim=1
        line=
        for ((c = 0; c < ncols; c++)); do
          ((VIS[c])) || continue
          v=${CELL[r*64+c]:-}; [ -z "$v" ] && v=-
          fit "$v" "${CW[c]}" "${RA[c]}"
          if ((TG[c])) && [ "$v" != - ] && ((dim == 0)); then
            [ -z "${tagc[$v]+x}" ] && { tagc[$v]=${TAGS[tagn % 4]}; tagn=$((tagn + 1)); }
            FIT="${tagc[$v]}$FIT$N"
          fi
          line+="$FIT  "
        done
        fit "${R_idx[r]}" 3 r; ip=$FIT; fit "${ST[r]}" "$stw"; stt=${FIT%"${FIT##*[! ]}"}
        case "$s" in
          run)    L+=("$C▸$ip$N  $B$line$N$C$stt$N");;
          done)   L+=(" $ip  $line$G$stt$N");;
          warn)   L+=(" $Y$ip$N  $line$Y$stt$N");;
          fail)   L+=(" $R$ip$N  $line$R$stt$N");;
          *)      L+=("$D $ip  $line$stt$N");;
        esac
      done
      L+=("$RULE")
      # footer: the most complete form that fits (full -> no zero counts -> short range -> symbols only)
      names=(done running queued warned skipped failed); syms=(✔ ▶ · ! – ✖); cols_=("$G" "$C" "$D" "$Y" "$D" "$R")
      counts=("$n_done" "$n_run" "$n_q" "$n_warn" "$n_skip" "$n_fail")
      ((n_fail == 0)) && cols_[5]=$D
      for tier in 1 2 3 4; do
        if ((tier >= 3)); then rng="$((off + 1))-$((off + avail))/$nrows"; else rng="showing $((off + 1))-$((off + avail)) of $nrows"; fi
        ft="$D$rng$N"; plain=$rng
        for k in 0 1 2 3 4 5; do
          n=${counts[k]}
          if ((tier == 1)); then ((k == 3 || k == 4)) && ((n == 0)) && continue
          else ((k > 0 && n == 0)) && continue; fi
          if ((tier == 4)); then t="${syms[k]}$n"; else t="${syms[k]} $n ${names[k]}"; fi
          ft+="  ${cols_[k]}$t$N"; plain+="  $t"
        done
        ((${#plain} <= W)) && break
      done
      L+=("$ft")
    fi
  fi

  if ((once)); then printf '%s\n' "${L[@]}"; exit 0; fi
  if [ "$FINISHED" != 1 ]; then
    cut_to "↑/↓ scroll · PgUp/PgDn page · g/G top/bottom · f follow · q close view (job keeps running) · every ${EVERY}s" "$W"
    L+=("$D$CUT$N")
  fi
  # whole frame in one write from the top-left: no flicker, no half-drawn frames
  printf -v frame '%s\033[K\n' "${L[@]}"
  printf '\033[H%s\033[J' "${frame%$'\n'}"
  [ "$FINISHED" = 1 ] && { printf '\n'; break; }

  if [ -t 0 ]; then
    if read -rsn1 -t "$EVERY" k; then
      case "$k" in
        q) printf '\n'; break;;
        f) follow=1;;
        k) follow=0; off=$((off - 1));;
        j) follow=0; off=$((off + 1));;
        g) follow=0; off=0;;
        G) follow=0; off=999999;;
        $'\e') read -rsn2 -t 0.05 k2
               case "$k2" in
                 '[A') follow=0; off=$((off - 1));;
                 '[B') follow=0; off=$((off + 1));;
                 '[5') read -rsn1 -t 0.05 _; follow=0; off=$((off - avail));;
                 '[6') read -rsn1 -t 0.05 _; follow=0; off=$((off + avail));;
               esac;;
      esac
    fi
  else
    sleep "$EVERY"
  fi
done
