#!/usr/bin/env bash
# Fake jobs that show how the board adapts its table to the job. Nothing real is touched.
#   examples/demo.sh [tests|downloads] [state-dir]
# then, in another terminal:  scripts/job-status.sh <state-dir>
here="$(cd "$(dirname "$0")/.." && pwd)"; source "$here/scripts/sb-lib.sh" || exit 1
kind=${1:-tests}; state=${2:-${TMPDIR:-/tmp}/sb-demo-$kind}

case "$kind" in
  tests)
    names=(parser lexer cache auth router render export); cases=(42 17 64 23 51 88 30)
    sb_init "$state" "Demo: test suites" ${#names[@]} "" "kill $$"
    sb_cols "Suite" "@Area" "Cases" "Result"
    for i in "${!names[@]}"; do area=core; ((i > 2)) && area=api; ((i > 4)) && area=ui; sb_item $((i+1)) "${names[i]}" $area "${cases[i]}" -; done
    for i in "${!names[@]}"; do
      n=$((i+1)); sb_start $n "${names[i]}"; sb_stage running
      for s in 1 2 3 4; do sleep 0.5; sb_progress "0.$((s*2))"; done
      if [ "${names[i]}" = auth ]; then sb_cell $n 4 "1 failing"; sb_fail "1 failing"
      else sb_cell $n 4 "${cases[i]} passed"; sb_ok; fi
    done ;;
  downloads)
    files=(dataset-a.tar dataset-b.tar weights.bin notes.pdf images.zip); mb=(400 250 900 3 120)
    total=0; for m in "${mb[@]}"; do total=$((total + m)); done
    sb_init "$state" "Demo: downloads" ${#files[@]} "$total" "kill $$"
    sb_cols "File" "Size" "@Mirror" "Took"
    for i in "${!files[@]}"; do sb_item $((i+1)) "${files[i]}" "${mb[i]} MB" "eu-1" -; done
    sb_skip 4 "already have it" 3
    for i in 0 1 2 4; do
      n=$((i+1)); m=${mb[i]}; sb_start $n "${files[i]}" "$m"; sb_stage downloading; got=0
      while ((got < m)); do sleep 0.3; got=$((got + 60)); ((got > m)) && got=$m; sb_progress "$got" "200 MB/s"; done
      sb_cell $n 4 "$(( (m + 199) / 200 ))s"; sb_ok
    done ;;
  *) echo "usage: $0 [tests|downloads] [state-dir]" >&2; exit 2 ;;
esac
sb_finish
echo "demo finished; state in $state"
