---
name: status-board
description: Use whenever running anything automated or long-running (builds, test suites, data or file batches, encodes, exports, downloads, migrations, scheduled or background jobs), or when the user asks for logging, progress or status. Shows the job as a live colour-coded board in a terminal (fixed summary, a table whose columns are chosen for the job, health, ETA, stop command) instead of raw log output.
---

# Status board

A live board for any long-running job. Layout, colours, symbols and health rules are always the same; the
table columns are chosen for each job. Paths below are relative to this skill's base directory.

1. Skim `STATUS-BOARD.md` once if you have not (layout, colours, health, file contract).
2. Make the job write its state. In a bash job script:
   ```bash
   source "<skill-dir>/scripts/sb-lib.sh"
   sb_init  "$STATE" "<what this job is>" <item-count> "<exact stop command>"   # or: <count> <total-weight> "<stop>"
   sb_cols  "<col>" "@<tag col>" "<col>"          # columns that matter for THIS job
   sb_item  1 "<cell>" "<cell>" "<cell>"          # once per item, up front
   sb_start 1 "<item label>" [weight]; sb_stage "<what it is doing>"
   sb_progress <done-weight> ["<rate text>"]      # as the item advances
   sb_track <expected-lines> -- <command> ...     # or: run a command, its output lines become progress
   sb_cell  1 3 "<value>"; sb_ok ["<note>"]       # or sb_warn / sb_fail "<reason>" / sb_skip <idx>
   sb_finish                                      # last line of the job
   ```
   - **Choose columns from the job**, never from habit or another job: what would the user want to see per
     item? Keep it to 2-5 columns. Prefix one grouping column with `@` to colour it; it hides itself while every row
     is in the same group.
   - Use a fresh state dir per job (e.g. `$(mktemp -d)/state`) and start the job detached
     (`setsid nohup bash job.sh >/dev/null 2>&1 &`) so it outlives the shell.
   - Jobs with long silent steps: set `SB_SLOW_AFTER` / `SB_STALL_AFTER` (seconds) before `sb_init`.
   - Programs other than bash can write the files directly (see `STATUS-BOARD.md`).
3. Show the board. The viewer command is `bash "<skill-dir>/scripts/job-status.sh" "$STATE"`.
   - **If you have a tool that runs a command in a terminal tab or pane the user can see** (e.g. a terminal panel
     in a desktop app or IDE), run the viewer there and read the pane back to confirm it renders.
   - **Otherwise (plain CLI, no such tool):** give the user that exact command to paste into a second terminal.
     Never run the live viewer through your own shell tool: it loops until the job ends and its output is hidden.
   - Either way, `bash "<skill-dir>/scripts/job-status.sh" --once "$STATE"` prints one plain frame. Use it to check
     the job yourself, and paste a frame into chat at meaningful moments if the user cannot see a live board.
4. **Required: tell the user how to watch and stop it.** Right after starting the job, run
   `bash "<skill-dir>/scripts/job-status.sh" --howto "$STATE"`. Then, before you wait on the job or do anything
   else, write a message to the user as normal reply text that includes its output, in this shape:

   > Started: <what is running>, about <duration>.
   > Watch: <the terminal tab you opened, or the `Watch:` command from --howto to paste into a second terminal>
   > Stop: <the `Stop:` command from --howto>

   Do not skip this when the job is short or the session is non-interactive; output inside a tool call is not
   seen by the user. (The plugin also shows the user a one-time notice with these commands when the job starts;
   your message is still required, since some clients do not display plugin notices.) When the job ends, report the outcome yourself (key lines of the final `--once` frame:
   done, failed, which items). The user should never have to ask for status.

`examples/demo.sh tests` and `examples/demo.sh downloads` run two fake jobs with different columns.
Requires bash 4.2+, awk, sed, tput.
