#!/usr/bin/env bash
# Tests for sb-lib.sh + job-status.sh. Run: tests/run.sh   (exit code = number of failed checks)
here="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$here/skills/status-board/scripts/sb-lib.sh"
VIEW="$here/skills/status-board/scripts/job-status.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STATUS_BOARD_HOME="$T/sb-home" CLAUDE_CODE_SESSION_ID=session-one   # keep the job list out of the real home
fails=0; checks=0
ok()   { checks=$((checks + 1)); }
bad()  { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL: %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    | /'; }
has()  { grep -qF -- "$2" <<<"$1" && ok || bad "$3: expected '$2'" "$1"; }
hasnt(){ grep -qF -- "$2" <<<"$1" && bad "$3: did not expect '$2'" "$1" || ok; }
view() { NO_COLOR=1 COLUMNS="${2:-100}" LINES=60 bash "$VIEW" --once "$1" </dev/null; }
source "$LIB"

# 1. full lifecycle, job-chosen columns, every row state
S=$T/one
sb_init "$S" "Nightly sync" 5 5 "kill 123"
sb_cols "Name" "@Group" "Count" "Note"
sb_item 1 alpha red 10 -; sb_item 2 beta red 20 -; sb_item 3 gamma blue 30 -; sb_item 4 delta blue 40 -; sb_item 5 eps red 50 -
sb_start 1 alpha; sb_ok "fine"
sb_start 2 beta; sb_fail "boom"
sb_start 3 gamma; sb_warn "slow mirror"
sb_skip 4 "already there"
sb_start 5 eps 1; sb_stage "copying"; sb_progress 0.5 "3 MB/s"
out=$(view "$S")
has "$out" "Nightly sync" "title"
has "$out" "Name" "job column 1"; has "$out" "Group" "tag column header without @"; hasnt "$out" "@Group" "@ marker hidden"
has "$out" "Count" "numeric column"; has "$out" "Status" "status column"
has "$out" "✔ fine" "done note"; has "$out" "✖ boom" "fail reason"; has "$out" "! slow mirror" "warn note"
has "$out" "– already there" "skip note"; has "$out" "▶ copying 50%" "running stage + item %"
has "$out" "NOW (5/5)  eps  [copying]" "NOW line"; has "$out" "rate 3 MB/s" "rate text"
has "$out" "1 failed" "failed count"; has "$out" "1 warned" "warned count"; has "$out" "1 skipped" "skipped count"
has "$out" "Stop     kill 123" "stop command"; has "$out" "● OK" "health ok"
has "$out" "Last     gamma: slow mirror" "last item"
for w in Clip Proxy Src realtime Length Source Speed; do hasnt "$out" "$w" "no built-in column names ($w)"; done
sb_ok; sb_finish
out=$(view "$S")
has "$out" "FINISHED" "finished"; has "$out" "100%" "100% when finished"; hasnt "$out" "NOW" "no NOW when finished"
has "$out" "4/5 done" "done count (ok + warn + skip + last ok)"

# 2. a tag column with one group hides; ordinary repeated values and placeholder-only columns stay
S=$T/two; sb_init "$S" "Hide test" 3
sb_cols "Item" "@Kind" "Verdict" "Result"; sb_item 1 a same no -; sb_item 2 b same no -; sb_item 3 c same no -
out=$(view "$S")
hasnt "$out" "Kind" "tag column with one group is hidden"; has "$out" "Verdict" "ordinary column with one repeated value is kept"; has "$out" "Result" "placeholder column is kept"

# 3. empty cells keep their column
S=$T/three; sb_init "$S" "Empty cells" 2
sb_cols "A" "B" "C"; sb_item 1 x "" z; sb_item 2 "" y ""
sb_cell 2 3 "w"
row1=$(view "$S" | grep -E '^ +1  '); row2=$(view "$S" | grep -E '^ +2  ')
[[ $row1 =~ x\ +-\ +z ]] && ok || bad "row 1 columns kept (x - z)" "$row1"
[[ $row2 =~ -\ +y\ +w ]] && ok || bad "row 2 columns kept (- y w)" "$row2"

# 4. nothing in state files is executed; tabs/newlines cannot break the table
S=$T/four; rm -f "$T/pwned"
sb_init "$S" "It's \$(touch $T/pwned) \`touch $T/pwned\` \"q\"" 1 1 "kill \$(cat x)"
sb_cols "Na	me" "Val"; sb_item 1 "multi
line" "tab	bed"; sb_start 1 "x\$(touch $T/pwned)"
out=$(view "$S")
[ -e "$T/pwned" ] && bad "state content was executed" || ok
has "$out" "It's \$(touch" "title shown literally"; has "$out" "multi line" "newline flattened"

# 5. fractional weights
S=$T/five; sb_init "$S" "Weights" 2 2.5
sb_start 1 a 2; sb_ok; sb_start 2 b 0.5; sb_progress 0.25
out=$(view "$S"); has "$out" " 90%" "overall % from fractional weights"; has "$out" " 50%" "item % from fractional weights"

# 5b. per-item weights without a total weight: each item still counts as one (no overflowing bar)
S=$T/fiveb; sb_init "$S" "Item weights" 4 "kill 1"
sb_start 1 a 3; sb_ok; out=$(view "$S"); has "$out" " 25%" "1 of 4 done is 25%"
sb_start 2 b 3; sb_progress 1.5; out=$(view "$S"); has "$out" " 37%" "overall counts items"; has "$out" " 50%" "item % uses its weight"
sb_ok; sb_skip 3 "" 3; out=$(view "$S"); has "$out" " 75%" "skip counts one item"

# 6. dead job is NOT RUNNING, quiet job is SLOW?/STALLED?
S=$T/six; sb_init "$S" "Dead" 2; sb_start 1 a
( exit 0 ) & dead=$!; wait "$dead"; echo "$dead" > "$S/job.pid"
has "$(view "$S")" "NOT RUNNING" "dead pid"
echo $$ > "$S/job.pid"; touch -d '@1' "$S"/*; out=$(view "$S"); has "$out" "STALLED?" "old timestamps"

# 7. narrow terminal: no line wider than the terminal
S=$T/seven; sb_init "$S" "A very long job title that goes on and on and on and on and on and on and on" 2
sb_cols "Path" "Owner" "Size"; sb_item 1 "/a/really/very/long/path/that/keeps/going/and/going/file.dat" someone 123456
sb_item 2 "/short" other 1; sb_start 1 "/a/really/very/long/path/that/keeps/going/and/going/file.dat"
sb_stage "a long stage name for testing"; sb_progress 0.3 "123.4 MB/s"; sb_track 10 -- echo "$(printf 'output %.0s' {1..30})"
sb_fail "a very long failure reason that would never fit in a narrow terminal at all"; sb_start 2 x; sb_progress 0.5 "9 items/s"
for w in 40 50 64 78; do
  out=$(view "$S" "$w"); long=$(awk -v m=$((w - 1)) '{ if (length($0) > m) print }' <<<"$out")
  [ -z "$long" ] && ok || bad "lines fit a $w-column terminal" "$long"
  out=$(FORCE_COLOR=1 COLUMNS=$w LINES=60 bash "$VIEW" --once "$S" </dev/null | sed 's/\x1b\[[0-9;]*m//g')
  long=$(awk -v m=$((w - 1)) '{ if (length($0) > m) print }' <<<"$out")
  [ -z "$long" ] && ok || bad "coloured lines fit a $w-column terminal" "$long"
done
grep -q $'\e\[' <<<"$(FORCE_COLOR=1 COLUMNS=80 bash "$VIEW" --once "$S" </dev/null)" && ok || bad "FORCE_COLOR turns colour on"
grep -q $'\e\[' <<<"$(COLUMNS=80 bash "$VIEW" --once "$S" </dev/null)" && bad "no colour when output is not a terminal" || ok
grep -q $'\e\[' <<<"$(view "$S")" && bad "NO_COLOR still has escapes" || ok

# 8. waiting for a job that has not started
out=$(view "$T/nothing"); has "$out" "Waiting for job state" "missing state dir"

# 9. sb_track: output lines become progress, exit code is kept
S=$T/nine; sb_init "$S" "Track" 1; sb_start 1 build 1
sb_track 100 -- seq 1 50; rc=$?
[ "$rc" = 0 ] && ok || bad "sb_track exit code 0"
grep -q '^done=0\.' "$S/progress" && ok || bad "sb_track wrote progress" "$(cat "$S/progress")"
[ "$(wc -l < "$S/output.log")" = 50 ] && ok || bad "sb_track logged output"
sb_track 10 -- false; [ $? = 1 ] && ok || bad "sb_track keeps a failing exit code"
has "$(view "$S")" "Output   50" "last output line shown"

# 10. tool-written progress (ffmpeg-style keys)
S=$T/ten; sb_init "$S" "External" 1 10; sb_start 1 item 10
printf 'out_time_us=5000000\nspeed=2.5x\nprogress=continue\n' > "$S/progress"
out=$(view "$S"); has "$out" " 50%" "out_time_us progress"; has "$out" "rate 2.5x" "speed= shown as rate"

# 11b. stop command given in the weight slot is understood
S=$T/stopslot; sb_init "$S" "Stop slot" 4 "pkill -f my-job"
out=$(view "$S"); has "$out" "Stop     pkill -f my-job" "stop command as 4th argument"
grep -q '^WEIGHT_TOTAL=4$' "$S/summary.env" && ok || bad "weight falls back to item count" "$(cat "$S/summary.env")"
sb_init "$S" "Both" 4 10 "kill 1"; grep -q '^WEIGHT_TOTAL=10$' "$S/summary.env" && grep -q '^STOP=kill 1$' "$S/summary.env" && ok || bad "weight + stop"

# 11c. --howto gives a pasteable watch/stop message
out=$(bash "$VIEW" --howto "$S"); has "$out" "Watch:   bash " "howto watch line"; has "$out" "Stop:    kill 1" "howto stop line"
has "$out" "Running: Both (4 items)" "howto running line"

# 11. no table at all still renders a board
S=$T/eleven; sb_init "$S" "No table" 3; sb_start 1 a; sb_ok
out=$(view "$S"); has "$out" "1/3 done" "board without items.tsv"; hasnt "$out" "Status" "no table header"

# 13. one item: compact layout (one progress line, Details instead of a one-row table)
S=$T/single; sb_init "$S" "One thing" 1 "kill 1"; sb_cols "File" "Size" "Note"; sb_item 1 big.iso "4 GB" -
sb_start 1 big.iso; sb_stage copying; sb_progress 0.25 "80 MB/s"
out=$(view "$S")
has "$out" "NOW      big.iso  [copying]" "single NOW line"; has "$out" " 25%" "single progress %"
has "$out" "Details  Size 4 GB" "cells become Details (name and placeholders left out)"
hasnt "$out" "Overall" "no separate overall bar"; hasnt "$out" "Status" "no one-row table"; hasnt "$out" "(1/1)" "no 1/1 counter"
sb_ok; sb_finish; out=$(view "$S")
has "$out" "100%" "single finished"; has "$out" "ETA done" "single eta done"; has "$out" "Details  File big.iso · Size 4 GB" "details after finish"

# 14. progress that cannot be measured: dashes and plain words, never a fake 0% or "calculating"
S=$T/unknown; sb_init "$S" "No total" 1 "kill 1"; sb_start 1 export "?"; sb_stage encoding; sb_count "54 MB written"
out=$(view "$S")
has "$out" "no % available" "unknown bar text"; has "$out" "ETA unknown - no % available" "unknown ETA says why"
has "$out" "54 MB written" "count shown"; hasnt "$out" "0%" "no fake 0%"; hasnt "$out" "calculating" "never 'calculating'"
S=$T/unknown2; sb_init "$S" "No total, batch" 3 "kill 1"; sb_cols "Shot"; sb_item 1 a; sb_item 2 b; sb_item 3 c
sb_start 1 a "?"; sb_stage rendering; out=$(view "$S")
has "$out" "unknown until the first item finishes" "batch ETA before any item is done"
has "$out" "▶ rendering" "row stage"; hasnt "$out" "▶ rendering 0%" "no % on an unmeasurable row"
sb_ok; sb_start 2 b; out=$(view "$S")
has "$out" "no % reported yet" "item that has reported nothing yet"; hasnt "$out" "calculating" "never 'calculating' (batch)"
sb_progress 0; has "$(view "$S")" "not enough progress yet" "measurable but too early"
for w in 40 50 64; do
  out=$(view "$T/unknown" "$w"); long=$(awk -v m=$((w - 1)) '{ if (length($0) > m) print }' <<<"$out")
  [ -z "$long" ] && ok || bad "unknown layout fits a $w-column terminal" "$long"
  out=$(view "$T/single" "$w"); long=$(awk -v m=$((w - 1)) '{ if (length($0) > m) print }' <<<"$out")
  [ -z "$long" ] && ok || bad "single layout fits a $w-column terminal" "$long"
done

# 15. a reported percentage and ETA (sb_pct) win, survive sb_progress, and the ETA counts down
S=$T/pct; sb_init "$S" "Reported" 1 "kill 1"; sb_start 1 render "?"; sb_count "54 MB written"; sb_pct 26 "21:00 left"
out=$(view "$S"); has "$out" " 26%" "reported %"; grep -qE 'ETA ~(21:00|20:5[89])' <<<"$out" && ok || bad "reported ETA" "$out"
hasnt "$out" "no % available" "a reported % makes it measurable"
sb_progress 0 "1 MB/s"; out=$(view "$S"); has "$out" " 26%" "sb_progress keeps the reported %"; has "$out" "rate 1 MB/s" "rate added"
has "$out" "54 MB written" "count kept"
touch -d "@$(( $(date +%s) - 60 ))" "$S/progress"; grep -qE 'ETA ~(20:00|19:5[89])' <<<"$(view "$S")" && ok || bad "ETA counts down" "$(view "$S")"
sb_pct junk 2>/dev/null && bad "sb_pct rejects a non-number" || ok
sb_pct 50 soon 2>/dev/null && bad "sb_pct rejects a non-duration" || ok

# 16. sb.sh: one command per update, state kept in the files
SBX="$here/skills/status-board/scripts/sb.sh"
S=$T/cli
"$SBX" "$S" init "From outside" 2 "cancel in the app"
[ -e "$S/job.pid" ] && bad "sb.sh init without SB_WATCH_PID writes no pid" || ok
"$SBX" "$S" cols "Item" "Result"; "$SBX" "$S" item 1 one -; "$SBX" "$S" item 2 two -
"$SBX" "$S" start 1 one; "$SBX" "$S" stage working; "$SBX" "$S" pct 40 90
out=$(view "$S"); has "$out" "NOW (1/2)  one  [working]" "cli start/stage"; has "$out" " 40%" "cli pct"
hasnt "$out" "NOT RUNNING" "no pid: health from updates only"; has "$out" "Stop     cancel in the app" "cli stop"
"$SBX" "$S" cell 1 2 fine; "$SBX" "$S" ok "fine"; "$SBX" "$S" start 2 two; "$SBX" "$S" fail "app crashed"; "$SBX" "$S" finish
out=$(view "$S"); has "$out" "FINISHED" "cli finish"; has "$out" "1/2 done, 1 failed" "cli counts"; has "$out" "✖ app crashed" "cli fail reason"
( exit 0 ) & dead=$!; wait "$dead"
SB_WATCH_PID=$dead "$SBX" "$T/cli2" init "Watched" 1; "$SBX" "$T/cli2" start 1 x
out=$(view "$T/cli2"); has "$out" "NOT RUNNING" "SB_WATCH_PID: exit of the watched process shows"
grep -q '^STOP=$' "$T/cli2/summary.env" && ok || bad "no default stop that would kill the watched process" "$(cat "$T/cli2/summary.env")"
"$SBX" "$T/nope" ok 2>/dev/null && bad "sb.sh before init fails" || ok

# 12. post-bash hook: one notice per job, only in the session that started it
HOOK="$here/hooks/post-bash.sh"
hook() { printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2" | CLAUDE_PLUGIN_ROOT="$here" bash "$HOOK"; }
rm -rf "$STATUS_BOARD_HOME"
out=$(hook session-one "ls"); [ -z "$out" ] && ok || bad "no notice without jobs" "$out"
S=$T/hooked; sb_init "$S" "Hooked job" 3 "pkill -f hooked"
out=$(hook session-two "ls"); [ -z "$out" ] && ok || bad "no notice in another session" "$out"
out=$(hook session-one "ls")
has "$out" '"systemMessage"' "notice emitted"; has "$out" 'job started: Hooked job (3 items)' "notice title"
has "$out" 'Stop:  pkill -f hooked' "notice stop line"; has "$out" "Watch: bash $VIEW" "notice watch line"
if command -v python3 >/dev/null; then python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" && ok || bad "notice is valid JSON" "$out"; fi
out=$(hook session-one "ls"); [ -z "$out" ] && ok || bad "notice shown only once" "$out"
( sleep 0.4; CLAUDE_CODE_SESSION_ID=session-one bash -c "source '$LIB'; sb_init '$T/late' 'Late job' 1" ) &
out=$(hook session-one "setsid nohup bash job.sh &"); wait
has "$out" 'job started: Late job' "background job registered a moment later is still announced"
out=$(STATUS_BOARD_NOTICE=0 bash -c "source '$LIB'; sb_init '$T/off' 'Off' 1"; hook session-one "ls" | STATUS_BOARD_NOTICE=0 cat >/dev/null; printf '{"session_id":"session-one"}' | STATUS_BOARD_NOTICE=0 bash "$HOOK")
[ -z "$out" ] && ok || bad "STATUS_BOARD_NOTICE=0 turns notices off" "$out"

echo "$((checks - fails))/$checks checks passed"
exit "$fails"
