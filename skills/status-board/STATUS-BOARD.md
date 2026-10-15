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
| yellow | warning / slow | `!` rows, `● SLOW?` |
| bold red | failed / stalled / not running | `✖` rows, `● STALLED?`, `● NOT RUNNING`, failed count |
| dim | queued, skipped, labels, secondary | `·` and `–` rows, field labels, hints |
| bold | emphasis | title, column header, percentages, ETA |
| blue, violet, orange, sage | tag values, in order of first appearance | the `@` column |

Symbols: `✔` done, `▶` running, `·` queued, `!` warning, `✖` failed, `–` skipped, `●` health, `▸` current row.
`NO_COLOR=1` turns colour off; symbols and layout still carry the meaning.

## Health (from fresh progress, never from "the process exists")

| State | Rule |
|---|---|
| `● OK` | a state file changed within `SLOW_AFTER` seconds (default 15) |
| `● SLOW?` | no change for `SLOW_AFTER`..`STALL_AFTER` seconds |
| `● STALLED?` | no change for more than `STALL_AFTER` seconds (default 60) |
| `● NOT RUNNING` | the pid in `job.pid` is gone and the job never called finish |
| `● FINISHED` | the job called finish (failures, if any, are shown next to it) |

Freshness is the newest mtime of `progress`, `current.env`, `summary.env`, `items.tsv` and `output.log`. Jobs with
long silent steps should raise the thresholds (`SB_SLOW_AFTER`, `SB_STALL_AFTER`) rather than fake progress.

## Percent and ETA

Overall % = (weight of processed items + done weight of the current item) / total weight. Weights are any unit
that matches the work (items, bytes, test cases, seconds of media); without weights every item counts 1.
ETA is extrapolated from elapsed time and percent, so jobs do not have to report a speed.

## File contract (`<state-dir>`)

`sb-lib.sh` writes all of these; any other program can too. Write each file atomically (write `name.tmp`, then
rename). The viewer never executes these files; it only reads the keys listed here.

| File | Content |
|---|---|
| `summary.env` | `KEY=value` lines: `TITLE TOTAL DONE FAILED WARNED SKIPPED WEIGHT_TOTAL WEIGHT_DONE STARTED FINISHED LAST STOP SLOW_AFTER STALL_AFTER` (`STARTED` = epoch seconds, `FINISHED` = 0/1) |
| `current.env` | `KEY=value` lines for the item in progress: `IDX NAME WEIGHT STAGE ITEM_START`; empty between items |
| `progress` | `done=<weight done in the current item>` and optional `rate=<free text>`. Programs that write ffmpeg-style `out_time_us=` / `speed=` work as-is |
| `job.pid` | pid of the job process |
| `items.tsv` | optional table, tab-separated: `#COLUMNS<TAB>name<TAB>name…`, then one row per item: `<idx><TAB><state>[:<detail>]<TAB><cell><TAB><cell>…` with state `queued`, `run`, `done`, `warn`, `fail` or `skip` |
| `output.log` | optional; the last line is shown as `Output` (written by `sb_track`) |
| `job.log` | human-readable history written by `sb-lib.sh`; not read by the viewer |

## Rules for the agent

1. Any automated or long-running task gets this board, not a bare `tail -f` or a wall of log lines.
2. Choose the columns for the job at hand.
3. Read the terminal pane back and check it renders before telling the user to look.
4. Say once: what is running, expected duration, where to look, the exact stop command. Then report completion
   or failure without being asked.
5. Health comes from fresh progress, never from "the process exists".
