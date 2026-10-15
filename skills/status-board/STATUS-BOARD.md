# Status board: specification

One look tells you what is running, how far along it is, whether it is healthy, and how to stop it. The
**layout, colour meanings, symbols and health rules are fixed**. The **table columns are not**: each job names
its own, chosen for what matters in that job.

## Layout (top to bottom)

```
<job title>                                                   bold
──────────────────────────────────────────────                dim rule
Overall  [██████████░░░░░░░░░░]  52%   12/23 done, 1 failed    bar colour = health
         elapsed 4:10   ETA ~3:51
NOW (13/23)  <current item>  [<stage>]                        cyan
         [██████░░░░░░░░░░░░░░]  31%   rate <job text>   item ETA ~0:42   running 0:19
Output   <last line of output.log, if the job keeps one>      dim
Health   ● OK - progressing (last update 1s ago)
Last     <previous item>: <note> (0:35)
Stop     <exact command that stops the job>
                                                              everything above stays fixed
   #  <column 1>  <column 2>  <column …>  Status              bold header; columns from the job
──────────────────────────────────────────────
  12  …           …           …           ✔ done              scrolling list, follows the
▸ 13  …           …           …           ▶ <stage> 31%       current item
  14  …           …           …           · queued
──────────────────────────────────────────────
showing 1-23 of 23  ✔ 11 done  ▶ 1 running  · 10 queued  ✖ 1 failed
```

Lines with nothing to say are left out: no `rate` unless the job gives one, no `Output` without an output log,
no `NOW` or `Stop` once finished, no table without `items.tsv`.

### One item

A job with one item does not repeat itself: no separate `Overall` bar, no `(1/1)`, no one-row table. The row's
cells (minus `-` placeholders and the item name) become a `Details` line.

```
<job title>
──────────────────────────────────────────────
NOW      <item>  [<stage>]
Progress [███████░░░░░░░░░░░░░░░░░░░░░░░]  26%   <count>   rate <job text>
         elapsed 12:31   ETA ~21:00
Details  <column> <value> · <column> <value>
Health   ● OK - progressing (last update 0s ago)
Stop     <exact command that stops the job>
```

### No percentage

When an item's progress cannot be measured (no known total), the bar is replaced by dim dashes that say so,
and the ETA says why there is none. There is never a bar stuck at 0%, and never "calculating" when nothing is
being calculated.

```
Progress [╌╌╌╌╌╌╌ no % available ╌╌╌╌╌╌╌]   54 MB written   rate 0.4 MB/s
         elapsed 2:28   ETA unknown - no % available
```

| Bar text | ETA text | When |
|---|---|---|
| `no % available` | `unknown - no % available` | the job marked the item unmeasurable (`sb_start … ?`) and no `pct=` was reported |
| `no % reported yet` | `unknown - no % reported yet` | the item has reported nothing yet |
| a real bar | `not enough progress yet` | measurable, but under 1% so far |
| a real bar | `~<time>` | extrapolated, or the tool's own `eta=` (counting down between reports) |
| | `unknown until the first item finishes` | several items, none done, current one has no % |

In a batch, `Overall` stays a real bar (items done out of the total); only the current item's bar turns into
dashes. The table's Status column shows the current item's % only when it is known. Narrow terminals get short
forms (`unknown`, `too early`, `unknown yet`).

## Columns

- The job declares them (`sb_cols`, or the `#COLUMNS` line of `items.tsv`). Pick what answers "what do I need at
  a glance for THIS job". Never carry column names over from a different kind of job.
- `#` is always first and `Status` always last; Status is generated from the row state.
- A column name starting with `@` is a tag column: each distinct value gets its own colour.
- Widths come from the data. Columns whose values all look numeric (`42`, `3.5 MB`, `0:42`, `98%`) align right.
- A tag (`@`) column whose value is the same on every row is hidden: one group says nothing. Ordinary columns
  always show, because a value repeated on every row (e.g. `no` in a result column) is still a result. Columns that are still
  all `-` stay visible, so the layout does not jump once values arrive.
- When the terminal is narrow, the widest columns are shortened with `…` so no line wraps.

## Colours and symbols (a colour never changes meaning)

| Colour | Meaning | Used for |
|---|---|---|
| green | done / healthy | `✔` rows, `● OK`, done counts |
| bold green | finished | `● FINISHED`, the final overall bar |
| bold cyan | active now | `NOW`, `▸` current row, `▶` status, current bar |
| yellow | warning, or no progress for a while | `!` rows, `● NO PROGRESS` (short) |
| bold red | failed / not running / no progress for too long | `✖` rows, `● NO PROGRESS` (long), `● NOT RUNNING`, failed count |
| dim (grey) | queued, skipped, labels, secondary, nobody watching | `·` and `–` rows, field labels, hints, `● NOT WATCHED` and its stale bar |
| bold | emphasis | title, column header, percentages, ETA |
| blue, violet, orange, sage | tag values, in order of first appearance | the `@` column |

Symbols: `✔` done, `▶` running, `·` queued, `!` warning, `✖` failed, `–` skipped, `●` health, `▸` current row.
`NO_COLOR=1` turns colour off; symbols and layout still carry the meaning.

## Health (only what the board actually knows)

Health never guesses what silence means. "No progress for 5:00" is a fact; "stalled" or "hung" would be a guess
(a long silent step is not a hang), so the board never says it.

A job that reports its own progress (a script using `sb-lib.sh`):

| State | Rule |
|---|---|
| `● OK` | a state file changed within `SLOW_AFTER` seconds (default 15) |
| `● NO PROGRESS for <time>` yellow | no change for `SLOW_AFTER`..`STALL_AFTER` seconds |
| `● NO PROGRESS for <time>` red | no change for more than `STALL_AFTER` seconds (default 60) |
| `● NOT RUNNING` | the pid in `job.pid` is gone and the job never called finish |
| `● FINISHED` | the job called finish (failures, if any, are shown next to it) |

Freshness is the newest mtime of `progress`, `current.env`, `summary.env`, `items.tsv` and `output.log`. Jobs with
long silent steps should raise the thresholds (`SB_SLOW_AFTER`, `SB_STALL_AFTER`) rather than fake progress.

A board fed by **readings** (`CHECK_EVERY` > 0: someone, usually Claude, reads the app and pushes `pct`/`count`
about every `CHECK_EVERY` seconds). Silence between readings is the schedule, not the job:

| State | Rule |
|---|---|
| `● OK - last reading 3 min ago (next check ~14:12)` | readings arrive on schedule |
| `● NO PROGRESS for <time> - same reading since 14:02` yellow / red | readings keep showing the same value for `SLOW_AFTER` / `STALL_AFTER` (sb.sh defaults 300 / 900) |
| `● NOT WATCHED - …. Ask Claude for an update` grey | `WATCHING=0` (Claude said it stopped checking), or no reading for more than `CHECK_EVERY` × 1.25 + 90 s (timers can fire late) |
| `● NOT RUNNING` | the watched app's pid (`SB_WATCH_PID`) is gone |

`ATTACHED` in `summary.env`: 0 = the board saw the job from its start; 1 = attached to a running job whose
start time was given (`SB_JOB_STARTED=<epoch>`, elapsed counts from it); 2 = attached, start unknown: the board
says `watched for` instead of `elapsed` and shows no extrapolated ETA (only one the tool reports).

While NOT WATCHED, the bar turns grey and shows the reading's time (`26%  at 14:02`), and the ETA becomes the
app's own estimate as a clock time (`around 14:23 (app's estimate at 14:02)`) instead of a live countdown.

## Percent and ETA

Overall % = (weight of processed items + done weight of the current item) / total weight. Weights are any unit
that matches the work (items, bytes, test cases, seconds of media); without weights every item counts 1.
ETA is extrapolated from elapsed time and percent, so jobs do not have to report a speed. A tool that reports its
own percentage or time left (`pct=`, `eta=` in `progress`) wins over both: what the tool knows is shown as is.

## File contract (`<state-dir>`)

`sb-lib.sh` writes all of these; any other program can too. Write each file atomically (write `name.tmp`, then
rename). The viewer never executes these files; it only reads the keys listed here.

| File | Content |
|---|---|
| `summary.env` | `KEY=value` lines: `TITLE TOTAL DONE FAILED WARNED SKIPPED WEIGHT_TOTAL WEIGHT_DONE STARTED FINISHED LAST STOP SLOW_AFTER STALL_AFTER WEIGHT_EXPLICIT CHECK_EVERY WATCHING ATTACHED` (`STARTED` = epoch seconds, `FINISHED` = 0/1, `CHECK_EVERY` = seconds between readings or 0, `WATCHING` = 0/1) |
| `current.env` | `KEY=value` lines for the item in progress: `IDX NAME WEIGHT STAGE ITEM_START`; empty between items |
| `current.env` (cont.) | also `ITEM_WEIGHT` (weight as given) and `MEASURABLE=0` for an item whose progress cannot be measured |
| `progress` | `done=<weight done in the current item>`, and optional `pct=<0-100 as the tool reports it>`, `eta=<seconds or h:mm:ss left, as the tool reports it>`, `count=<free text, e.g. 54 MB written>`, `rate=<free text>`, `read=<epoch of the last reading>`, `since=<epoch since the reading has had this value>`. Programs that write ffmpeg-style `out_time_us=` / `speed=` work as-is |
| `job.pid` | pid of the process whose exit means NOT RUNNING (the job, or with `SB_WATCH_PID` the app doing the work). Optional: without it, health comes from fresh updates alone |
| `items.tsv` | optional table, tab-separated: `#COLUMNS<TAB>name<TAB>name…`, then one row per item: `<idx><TAB><state>[:<detail>]<TAB><cell><TAB><cell>…` with state `queued`, `run`, `done`, `warn`, `fail` or `skip` |
| `output.log` | optional; the last line is shown as `Output` (written by `sb_track`) |
| `job.log` | human-readable history written by `sb-lib.sh`; not read by the viewer |

## Rules for the agent

1. Use the board for a batch of 2+ items that runs more than about a minute, for one item over about 1-2 minutes
   whose progress can be measured, or when the user asks. Not for a single task with no measurable progress:
   say what is running and how to stop it, then report the result.
2. Get progress from the source first (the app's or tool's own percentage and time left); a proxy counts only
   when its total is known. Mark unmeasurable items as such instead of showing 0%.
3. The board never shows less than you know: push every number you read (`sb.sh <state> pct <n> [eta]`).
4. Choose the columns for the job at hand.
5. Read the terminal pane back and check it renders before telling the user to look.
6. Say once: what is running, expected duration, where to look, the exact stop command. Then report completion
   or failure without being asked.
7. Health comes from fresh progress, never from "the process exists", and never claims more than it knows: no
   progress is reported as "no progress for <time>", nobody checking as "NOT WATCHED".
8. Progress inside an app: feed the board from a background script that reads the app (CLI, API, control
   port, status file) whenever one can; it costs nothing and keeps the chat quiet.
9. Check-ins (Claude coming back on a timer) are off by default: each one uses the user's usage and fills the
   chat. Offer them only when no script can read the progress, ask first with "No check-ins" recommended and at
   least three intervals that fit the job (never under 10 minutes).
