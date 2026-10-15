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

A single item gets a shorter board, and progress with no known total says so instead of sitting at 0%:

```
Export: final cut
────────────────────────────────────────────────────────────────────────────────
NOW      final cut.mp4  [encoding]
Progress [╌╌╌╌╌╌╌ no % available ╌╌╌╌╌╌╌]   54 MB written   rate 0.4 MB/s
         elapsed 2:28   ETA unknown - no % available
Health   ● OK - progressing (last update 0s ago)
Stop     cancel it in the app's export queue
```

When the app doing the work reports its own percentage and time left, those go on the board as they are:

```
Progress [███████░░░░░░░░░░░░░░░░░░░░░░░]  26%   54 MB written   rate 0.4 MB/s
         elapsed 12:31   ETA ~21:00
```

## Install

In Claude Code:

```
/plugin marketplace add Tyaaa-aa/status-board
/plugin install status-board@status-board
```

Then start a new Claude Code session. From then on Claude uses the board by itself when it helps: a batch of
2 or more items that runs more than about a minute, or one task over about 1-2 minutes whose progress can be
measured. A single task with no percentage gets no board (just "started / how to stop" and the result). You can
always ask for it ("run the migration with a status board").

How it works: two small hooks, nothing else.
- At the start of each session, one adds a short note telling Claude when to use the board.
- When Claude starts a job, the other shows you a one-time notice in the chat, written by the plugin itself so it
  is never forgotten:

  ```
  status-board · job started: Resize photos (3 items)
    Watch: bash …/job-status.sh /tmp/…/state
    Stop:  kill 12345
  ```

The hooks run no jobs and send nothing anywhere. They keep a small list of started jobs in
`~/.local/state/status-board/`. Turn the notice off with `STATUS_BOARD_NOTICE=0`, or the whole plugin with
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

Mark an item whose progress cannot be measured with `sb_start <idx> "<label>" ?`, report what has happened with
`sb_count "54 MB written"`, and pass a tool's own figures with `sb_pct 26 21:00`.

From outside a script (one command per update, e.g. progress read from an app):

```bash
sb=skills/status-board/scripts/sb.sh
$sb /tmp/export init "Export: final cut" 1 "cancel it in the app"
$sb /tmp/export start 1 "final cut.mp4"; $sb /tmp/export pct 26 21:00
$sb /tmp/export ok; $sb /tmp/export finish
```

Any language can drive the board by writing the plain files described in
[`STATUS-BOARD.md`](skills/status-board/STATUS-BOARD.md). The viewer never executes them.

Requires bash 4.2+ (macOS: `brew install bash`), awk, sed, tput. `NO_COLOR=1` disables colour; it is also off
when output is not a terminal unless `FORCE_COLOR=1`.

## Files

| Path | What |
|---|---|
| `hooks/` | the session-start note (Claude uses the board unasked) and the "job started" notice for you |
| `skills/status-board/SKILL.md` | instructions Claude follows |
| `skills/status-board/STATUS-BOARD.md` | the spec: layout, colours, health rules, file contract |
| `skills/status-board/scripts/sb-lib.sh` | bash helpers a job uses to write its state |
| `skills/status-board/scripts/sb.sh` | the same helpers as one-shot commands (`sb.sh <state> pct 26 21:00`) |
| `skills/status-board/scripts/job-status.sh` | the viewer (`--once` prints one plain frame) |
| `skills/status-board/examples/demo.sh` | two fake jobs |
| `tests/run.sh` | test suite |
| `tests/fresh-session.sh` | behaviour test: does a fresh Claude session use the board unasked? (costs tokens) |

## License

MIT
