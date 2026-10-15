# Changelog

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
