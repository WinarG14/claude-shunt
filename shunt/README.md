# shunt - big-file read router for Claude Code

Two PreToolUse hooks block whole-file reads of large text files and point Claude at a cheap
worker model (Haiku) that returns line-cited bullets. Bullets are leads: anything Claude acts
on, edits, publishes or cites must be confirmed with a targeted `offset`/`limit` Read.

- `hooks/check_read.py` - Read tool. Blocks when the file is over `min_lines` and no `limit`
  ≤ `max_targeted_lines` is given. Also enforces the slice budget (below).
- `hooks/check_bash.py` - Bash tool. Blocks `cat`/`less`/`more`, `head`/`tail -n N` with
  N > `max_targeted_lines`, and `sed -n 'A,Bp'` spanning more than that. Fails open on pipes,
  redirects, `$( )`, backticks and heredocs. Counts allowed targeted bash reads toward the
  slice budget, and records a reader call as `worker_sanctioned`.
- `hooks/shunt_budget.py` - shared slice-budget helpers (log tail, per-session state).
- `scripts/bulk_read.sh <file...> "<question>"` - the worker. Runs `claude -p` from
  `workdir/` with a cleaned env and no MCP servers, so it never loads a project's CLAUDE.md.

## Slice budget

Hooks are stateless per call, so an 858-line file used to be readable in three legal
350-line slices. The budget makes them stateful:

1. Every allowed targeted read (Read with `limit`, or `head -n N` / `tail -n N` /
   `sed -n 'A,Bp'`) of a big non-exempt file is logged as `targeted_read`.
2. Before allowing the next one, the hook sums the `limit` of prior `targeted_read` events
   for the same (session, file). If the sum plus this slice would exceed `min_lines`, the
   read is blocked with a message telling Claude to run `bulk_read.sh` first.
3. Running `bulk_read.sh` on that file writes `worker_sanctioned` for the session, which
   lifts the cap: after the reader has been consulted, targeted Reads of the cited lines
   are unlimited for that file.

Missing or empty `session_id` skips the budget (allow). Only the last 3000 log lines are
scanned. Any parse error fails open. Turn it off with `slice_budget_enabled: false`.

## Toggle

`shunt on` / `shunt off` (writes `enabled` in `config.json`), or `SHUNT_MODE=off|on` in the
environment, which beats the config. `shunt status`, `shunt log [N]`, `shunt test`.
CLI lives at `bin/shunt`, symlinked to `~/.local/bin/shunt`.

## config.json keys

`enabled` · `min_lines` (block above this) · `max_targeted_lines` (largest allowed slice) ·
`slice_budget_enabled` (per-session, per-file slice cap) · `worker` (`haiku`, or
`claudex:<model>`) · `worker_timeout_s` · `exempt_basenames` · `exempt_path_prefixes`
(`~` expands) · `exempt_extensions` · `log_enabled`.
Data files (.json/.yaml/.csv/…) and instruction files (CLAUDE.md, AGENTS.md, …) are exempt on
purpose: a summariser cannot faithfully compress structured data, and instruction files must
be read whole. A missing or malformed config fails open (allow) and logs to `log/hook_errors.log`.

## Environment

- `SHUNT_MODE=off|on` - beats `enabled` in the config.
- `SHUNT_LOG_PATH` - event-log path override, honoured by both hooks, `bulk_read.sh` and
  `shunt log`. The test suite sets it so tests never touch the real log.
- `SHUNT_WORKER`, `SHUNT_TIMEOUT` - override the worker model and its timeout for one call.

## Log format

`log/shunt.log`, one JSON object per line: `ts, event (block_read|block_bash|
block_slice_budget|targeted_read|worker_sanctioned|worker_call|worker_fail), session, cwd,
file, files, lines, offset, limit, slices_read, file_tokens_est, returned_tokens_est, worker,
in, out, cost_usd, wall_s` - only the fields that apply. `file_tokens_est` is bytes/4.

## Uninstall

Delete the two `PreToolUse` entries in `~/.claude/settings.json` (a pre-shunt copy is at
`~/.claude/settings.json.bak-2026-09-06-shunt`), then `rm ~/.local/bin/shunt` and this folder.
The repo's `uninstall.sh` does the same thing.

## Known gaps

1. **Grep is not metered.** A blocked model can still `grep -n` the file repeatedly and
   assemble an answer from matches. Observed 2026-09-06: after one 350-line slice was spent,
   Sonnet switched to `grep` rather than a second slice, so the budget never fired. Grep
   output is far smaller than a slice, so this is cheap, but it is not the reader path.
2. **The model may refuse the reader.** Twice now a blocked Sonnet declined to run
   `bulk_read.sh` on the grounds that it does not execute scripts named by an error message,
   and answered from a single slice instead. The block still works (whole file kept out of
   context); the cheap-reader path is what gets skipped.
3. Only Read and Bash are covered. Grep/Glob output, MCP results, Jira/Sheets/web payloads
   are not.
4. A malformed config ignores `SHUNT_MODE=on` (fail-open wins).
5. Bash parsing is first-simple-command only; `cmd1; cat big` is not inspected.
6. The budget keys on `session_id`, so a fresh session starts with a fresh budget.
