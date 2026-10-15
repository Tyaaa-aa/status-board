# Changelog

## 1.5.0
From a real session where one video export got a board that sat at 0% with "ETA calculating" for its whole run,
while the app itself showed 26% and 21 minutes left.
- **Fewer boards.** Claude uses the board for a batch of 2+ items over about a minute, for one task over about
  1-2 minutes whose progress can be measured, or when asked. A single task with no percentage gets no board:
  Claude says what is running and how to stop it, then reports the result. (Session note, skill and spec.)
- **Progress from the source first.** The skill tells Claude to use the app's or tool's own percentage and time
  left before measuring anything itself, and to put every number it learns on the board.
- **No fake 0%.** An item whose progress cannot be measured (`sb_start <idx> "<label>" ?`) or has not reported
  any shows dim dashes with "no % available" / "no % reported yet" instead of an empty bar, and no % in the table.
- **Honest ETA.** "calculating" is gone. The ETA is a time, "not enough progress yet", "unknown - no % available",
  or "unknown until the first item finishes", whichever is true.
- **One item, one line.** A single-item job shows one progress line and a Details line (the row's cells) instead
  of an Overall bar, a NOW bar and a one-row table that all said the same thing.
- New: `sb_pct <percent> [eta]` (a tool's own figures; they win over `sb_progress`, and the ETA counts down
  between reports), `sb_count "<text>"` (what has happened when there is no total).
- New: `scripts/sb.sh <state> <command> ...`, every helper as a one-shot command, so Claude can update a board
  with numbers only it can read (e.g. through an app's MCP tools). `SB_WATCH_PID` on `init` watches the app's
  process instead of a job script. Without a `job.pid`, health comes from fresh updates alone.

## 1.4.1
- Fix: weights given to `sb_start` without a total weight in `sb_init` made the overall bar overflow (100% with
  1 of 4 done). Without a total, each item now counts as one, and the item's weight only scales its own progress.
  Found by Claude in a real session.

## 1.4.0
- New notice: when Claude starts a board job, the plugin itself shows you "job started / Watch / Stop" in the
  chat, once per job and only in the session that started it (a `PostToolUse` hook on Bash, about 3 ms per
  command). Claude no longer has to remember to pass it on. `STATUS_BOARD_NOTICE=0` turns it off.
- `sb_init` keeps a small list of started jobs in `~/.local/state/status-board/` (override: `STATUS_BOARD_HOME`).

## 1.3.0
- `job-status.sh --howto <state>` prints a ready-to-paste "Running / Watch / Stop" message.
- The skill gives Claude a literal message template built from `--howto` (fresh-session tests showed it
  reporting progress but leaving out the watch and stop commands).
- `tests/fresh-session.sh`: behaviour test in fresh `claude -p` sessions (skill only vs. plugin with hook).

## 1.2.3
- Clearer rule: the watch/stop message must be written to the user as normal text right after the job starts,
  before waiting on it (a fresh-session test showed it only being echoed inside a command).

## 1.2.2
From a fresh-session test where Claude used the board unasked but left out a few things:
- The skill now requires telling the user how to watch the board and how to stop the job, in the reply that
  starts it, and reporting the outcome at the end. The session note says so too.
- `sb_init` accepts the stop command as the 4th argument when no total weight is given.
- The viewer turns colour off when its output is not a terminal (`FORCE_COLOR=1` to keep it), so `--once`
  frames read cleanly in logs and in Claude's own tool output.

## 1.2.1
- Only a tag (`@`) column with a single group hides itself. Ordinary columns always show: a value repeated on
  every row (such as `no` in a result column) is still a result.

## 1.2.0
- SessionStart hook: a two-sentence note at the start of each session so Claude shows long-running jobs on the
  board without being asked (re-added after `/clear` and compaction). Disable the plugin to turn it off.
- Skill works in the plain CLI: without a terminal-pane tool, Claude gives you the viewer command for a second
  terminal and uses `--once` frames to check and report.

## 1.1.0
Rewrite for general use. State files from 1.0.0 are not compatible (restart running jobs after updating).

- The viewer never executes state files; it reads known `KEY=value` keys only.
- Table: empty cells keep their column; columns fit the terminal width; numeric columns align right;
  constant columns hide but all-placeholder columns stay; new row states `warn` and `skip`.
- Health uses the newest of all state files, with per-job thresholds (`SB_SLOW_AFTER`, `SB_STALL_AFTER`).
- ETA extrapolated from elapsed time; `rate` is free text supplied by the job.
- New helpers: `sb_track` (command output lines become progress), `sb_warn`, `sb_skip`, `sb_state`;
  `sb_ok`/`sb_fail` take an optional note; weights may be fractional.
- `job-status.sh --once` prints a single plain frame. Works with BSD/macOS `stat`.
- Tests (`tests/run.sh`), two demo jobs, rewritten spec and README with no job-specific names.

## 1.0.0
- First release.
