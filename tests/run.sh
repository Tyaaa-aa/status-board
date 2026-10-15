#!/usr/bin/env bash
# Tests for sb-lib.sh + job-status.sh. Run: tests/run.sh   (exit code = number of failed checks)
here="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$here/skills/status-board/scripts/sb-lib.sh"
VIEW="$here/skills/status-board/scripts/job-status.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
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
  out=$(COLUMNS=$w LINES=60 bash "$VIEW" --once "$S" </dev/null | sed 's/\x1b\[[0-9;]*m//g')
  long=$(awk -v m=$((w - 1)) '{ if (length($0) > m) print }' <<<"$out")
  [ -z "$long" ] && ok || bad "coloured lines fit a $w-column terminal" "$long"
done
grep -q $'\e\[' <<<"$(COLUMNS=80 bash "$VIEW" --once "$S" </dev/null)" && ok || bad "colour is on without NO_COLOR"
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

# 11. no table at all still renders a board
S=$T/eleven; sb_init "$S" "No table" 3; sb_start 1 a; sb_ok
out=$(view "$S"); has "$out" "1/3 done" "board without items.tsv"; hasnt "$out" "Status" "no table header"

echo "$((checks - fails))/$checks checks passed"
exit "$fails"
