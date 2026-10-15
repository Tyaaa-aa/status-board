---
name: status-board
description: Use when running a batch of 2 or more items that takes more than about a minute (builds, test suites, file or data batches, encodes, downloads, migrations), or one task over about 1-2 minutes whose progress can be measured (a percentage or known total), or when the user asks for logging, progress or status. Not for a single task with no measurable progress. Shows the job as a live colour-coded board in a terminal (summary, progress, health, ETA, stop command, a table whose columns are chosen for the job) instead of raw log output.
---

# Status board

A live board for any long-running job. Layout, colours, symbols and health rules are always the same; the
table columns are chosen for each job. Paths below are relative to this skill's base directory.

0. **Decide whether a board helps.** Use one when any of these is true:
   - **2 or more items** and the job takes more than about a minute;
   - **one item** that takes more than about 1-2 minutes **and has measurable progress** (see step 1);
   - the user asks for progress, status or logging.

   Otherwise, do not open a board: a single task with no percentage would only show a bar that never moves. Start
   it in the background, say in one line what is running and how to stop it, and report the result when it ends.
1. **Get progress from the source first.** Before measuring anything yourself, look for the progress the work
   already reports: the app's own job or export status (through its MCP tools, API or UI text), a CLI's
   `--progress` / `-progress` output, a server's job endpoint. A proxy (file size, line count) counts only when
   its total is known. If nothing gives a percentage, the item is **unmeasurable**: say so (`sb_start ... ?`),
   never fake it with a 0% bar.
2. Skim `STATUS-BOARD.md` once if you have not (layout, colours, health, file contract).
3. Make the job write its state. In a bash job script:
   ```bash
   source "<skill-dir>/scripts/sb-lib.sh"
   sb_init  "$STATE" "<what this job is>" <item-count> "<exact stop command>"   # or: <count> <total-weight> "<stop>"
   sb_cols  "<col>" "@<tag col>" "<col>"          # columns that matter for THIS job
   sb_item  1 "<cell>" "<cell>" "<cell>"          # once per item, up front
   sb_start 1 "<item label>" [weight]; sb_stage "<what it is doing>"   # weight "?" = progress cannot be measured
   sb_progress <done-weight> ["<rate text>"]      # as the item advances
   sb_pct <percent> [eta]                         # or: the percentage / time left the tool itself reports
   sb_count "<text>"                              # no total: what has happened so far ("54 MB written")
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
   - **Progress that lives inside an app** (an export, a render, a sync): **first look for a way a script can
     read it**: the app's CLI, HTTP API, control port or socket, a status/progress file, a log line with a %. If
     one exists, run a small background script that polls it every few seconds and feeds the board with
     `bash "<skill-dir>/scripts/sb.sh" "$STATE" <command> [args]` (`init`, `start`, `stage`, `pct`, `count`,
     `ok`, `fail`, `finish`; same arguments as the `sb_` helpers) and finishes it when the work ends. That keeps
     the board live at no cost and with nothing in the chat; you only come back when the script exits.
   - On `init`, pass `SB_CHECK_EVERY=<seconds between readings>`, `SB_WATCH_PID=<app pid>` (NOT RUNNING if the app
     dies) and, when the job was already running, `SB_JOB_STARTED=<epoch it started>` or `SB_JOB_STARTED=unknown`
     (the board then says "watched for" and never guesses an ETA from progress it only partly saw).
   - **Whenever you learn a number, put it on the board** (`sb.sh "$STATE" pct 26 21:00`); it must never show
     less than you know. Health follows the reading schedule: OK while readings arrive, NO PROGRESS (yellow, then
     red) only when readings stay the same, grey **NOT WATCHED** when readings stop. It never calls a job stuck
     because nobody is looking.
   - **Only you can read it** (MCP tools or screenshots, no script can): push readings while you are working in
     this turn. When you finish replying, run `sb.sh "$STATE" unwatched` and tell the user you have stopped
     checking, that the board keeps the last reading with its time, and that they can ask you for an update any
     time. See **Check-ins** for the rare case where they want more.
4. Show the board. The viewer command is `bash "<skill-dir>/scripts/job-status.sh" "$STATE"`.
   - **If you have a tool that runs a command in a terminal tab or pane the user can see** (e.g. a terminal panel
     in a desktop app or IDE), run the viewer there and read the pane back to confirm it renders.
   - **Otherwise (plain CLI, no such tool):** give the user that exact command to paste into a second terminal.
     Never run the live viewer through your own shell tool: it loops until the job ends and its output is hidden.
   - Either way, `bash "<skill-dir>/scripts/job-status.sh" --once "$STATE"` prints one plain frame. Use it to check
     the job yourself, and paste a frame into chat at meaningful moments if the user cannot see a live board.
5. **Required: tell the user how to watch and stop it.** Right after starting the job, run
   `bash "<skill-dir>/scripts/job-status.sh" --howto "$STATE"`. Then, before you wait on the job or do anything
   else, write a message to the user as normal reply text that includes its output, in this shape:

   > Started: <what is running>, about <duration>.
   > Watch: <the terminal tab you opened, or the `Watch:` command from --howto to paste into a second terminal>
   > Stop: <the `Stop:` command from --howto>

   Do not skip this when the job is short or the session is non-interactive; output inside a tool call is not
   seen by the user. (The plugin also shows the user a one-time notice with these commands when the job starts;
   your message is still required, since some clients do not display plugin notices.) When the job ends, report the outcome yourself (key lines of the final `--once` frame:
   done, failed, which items). The user should never have to ask for status.

## Check-ins (off by default; rarely worth it)

A check-in is you coming back on a timer to read the app. Each one is a full model turn: it uses the user's
usage and shows up in the chat as tool calls and a message, which is what a board is meant to avoid. So:

- Never schedule check-ins without asking, and never more often than every 10 minutes.
- Offer them only when the progress is readable by you alone (no script can, see above) **and** the job will
  run well past your reply. Ask with the AskUserQuestion tool, with **"No check-ins (Recommended)" first**,
  then at least three choices that fit the job: once, near the expected end; about every half of the remaining
  time; about every quarter of it (never under 10 minutes). Say plainly that each check-in uses their usage and
  appears in the chat.
- **Yes:** schedule with CronCreate (an off-minute; the prompt names the state dir, how to read the progress,
  and to stop when the job ends), run `sb.sh "$STATE" watch <interval-seconds>`. On each fire: read, push the
  reading, reply with one short line. When the job ends: `ok`/`fail`, `finish`, CronDelete, report the result.
  Check-ins live only in this session; if it closes, the board turns NOT WATCHED on its own.
- **No (the default):** `sb.sh "$STATE" unwatched`, and tell the user they can ask you for an update any time.

`examples/demo.sh tests` and `examples/demo.sh downloads` run two fake jobs with different columns.
Requires bash 4.2+, awk, sed, tput.
