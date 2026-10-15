# status-board

A Claude Code plugin that shows long-running jobs as a live, colour-coded board in the terminal instead of a
wall of log lines: what is running now, overall and per-item progress, ETA, health (OK / slow / stalled / not
running) and the exact command to stop it.

The layout, colours and health rules never change. **The table does**: each job picks its own columns.
Two fake jobs from `examples/demo.sh`:

```
Demo: test suites
────────────────────────────────────────────────────────────────────────────────
Overall  [██████████████████░░░░░░░░░░░░]  62%   3/7 done, 1 failed
         elapsed 0:10   ETA ~0:05
NOW (5/7)  router  [running]
         [████████████░░░░░░░░░░░░░░░░░░]  40%   item ETA ~0:03   running 0:02
Health   ● OK - progressing (last update 1s ago)
Last     auth FAILED: 1 failing (0:02)
Stop     kill 63765

   #  Suite   Area  Cases  Result     Status
────────────────────────────────────────────────────────────────────────────────
   1  parser  core     42  42 passed  ✔ done
   2  lexer   core     17  17 passed  ✔ done
   3  cache   core     64  64 passed  ✔ done
   4  auth    api      23  1 failing  ✖ 1 failing
▸  5  router  api      51  -          ▶ running 40%
   6  render  ui       88  -          · queued
   7  export  ui       30  -          · queued
────────────────────────────────────────────────────────────────────────────────
showing 1-7 of 7  ✔ 3 done  ▶ 1 running  · 2 queued  ✖ 1 failed
```

```
Demo: downloads
────────────────────────────────────────────────────────────────────────────────
Overall  [█████████████░░░░░░░░░░░░░░░░░]  46%   3/5 done
         elapsed 0:05   ETA ~0:05
NOW (3/5)  weights.bin  [downloading]
         [███░░░░░░░░░░░░░░░░░░░░░░░░░░░]  13%   rate 200 MB/s   item ETA ~0:06
Health   ● OK - progressing (last update 1s ago)
Last     dataset-b.tar (0:02)
Stop     kill 63767

   #  File             Size  Took  Status
────────────────────────────────────────────────────────────────────────────────
   1  dataset-a.tar  400 MB    2s  ✔ done
   2  dataset-b.tar  250 MB    2s  ✔ done
▸  3  weights.bin    900 MB     -  ▶ downloading 13%
   4  notes.pdf        3 MB     -  – already have it
   5  images.zip     120 MB     -  · queued
────────────────────────────────────────────────────────────────────────────────
showing 1-5 of 5  ✔ 2 done  ▶ 1 running  · 1 queued  – 1 skipped  ✖ 0 failed
```

(The downloads job also declared a `@Mirror` tag column; every file came from the same mirror, so the board hid it.)

## Install

In Claude Code:

```
/plugin marketplace add Tyaaa-aa/status-board
/plugin install status-board@status-board
```

Then start a new Claude Code session. From then on Claude shows long-running and multi-item work on the board
by itself; you can also ask for it ("run the migration with a status board").

How it knows: a small `SessionStart` hook adds two sentences to each session saying that long jobs go on the board.
That is the only thing the hook does (it runs no job and reads nothing). Turn it off with
`/plugin disable status-board@status-board`.

In the desktop app or an IDE with a terminal panel, Claude opens the board there. In a plain terminal it gives you
the one command to run in a second terminal window.

## Update

```
/plugin marketplace update status-board
/plugin update status-board@status-board
```

## Use it without Claude

```bash
cd skills/status-board
examples/demo.sh tests /tmp/sb-demo &           # a fake job writing its state
scripts/job-status.sh /tmp/sb-demo              # the live board (q closes the view; the job keeps running)
```

In your own bash job:

```bash
source skills/status-board/scripts/sb-lib.sh
sb_init  /tmp/myjob "Resize photos" 3 "kill $$"
sb_cols  "Photo" "@Album" "Pixels"
sb_item  1 a.jpg trip 12M; sb_item 2 b.jpg trip 8M; sb_item 3 c.jpg home 24M
for i in 1 2 3; do sb_start $i "photo $i"; sb_stage resizing; resize_one $i && sb_ok || sb_fail "resize error"; done
sb_finish
```

Any language can drive the board by writing the plain files described in
[`STATUS-BOARD.md`](skills/status-board/STATUS-BOARD.md). The viewer never executes them.

Requires bash 4.2+ (macOS: `brew install bash`), awk, sed, tput. `NO_COLOR=1` disables colour; it is also off
when output is not a terminal unless `FORCE_COLOR=1`.

## Files

| Path | What |
|---|---|
| `hooks/` | the `SessionStart` note that makes Claude use the board unasked |
| `skills/status-board/SKILL.md` | instructions Claude follows |
| `skills/status-board/STATUS-BOARD.md` | the spec: layout, colours, health rules, file contract |
| `skills/status-board/scripts/sb-lib.sh` | bash helpers a job uses to write its state |
| `skills/status-board/scripts/job-status.sh` | the viewer (`--once` prints one plain frame) |
| `skills/status-board/examples/demo.sh` | two fake jobs |
| `tests/run.sh` | test suite |

## License

MIT
