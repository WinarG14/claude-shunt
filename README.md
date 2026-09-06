# claude-shunt

Keep large files out of your Claude Code context. Two `PreToolUse` hooks block whole-file
reads of big text files and point the model at a cheap reader model that answers a specific
question in line-cited bullets. You get the facts and the line numbers, not fifteen thousand
tokens of file.

Inspired by the write-up of a similar idea at Spotify:
https://engineering.atspotify.com/2026/9/portal-by-spotify-cut-my-claude-code-token-usage-by-90

## Why

A single 900-line document can cost more context than the whole task that needed it, and once
it is in the transcript you pay for it again on every later turn through cache reads. Most of
the time you did not want the file. You wanted three facts out of it.

The shunt makes that the default path:

1. The main model tries to read a big file.
2. The hook blocks the read and tells it to run `bulk_read.sh <file> "<question>"`.
3. That script sends the file to a cheap model with a strict prompt and gets back bullets,
   each one starting with `L<line>` or `L<a>-<b>`.
4. The main model then does small targeted reads of the cited lines to confirm anything it
   is going to act on, edit, publish or quote.

Bullets are leads, not evidence. That rule is in the block message and in the reader's own
system prompt.

## What is in the box

```
install.sh          install or re-install, wire the hooks, symlink the CLI
uninstall.sh        remove the hooks (--purge also deletes the install)
shunt/              the harness itself, copied to ~/.claude/shunt
  hooks/check_read.py     Read tool gate plus slice budget
  hooks/check_bash.py     Bash tool gate, budget metering, reader sanctioning
  hooks/shunt_budget.py   shared budget helpers
  scripts/bulk_read.sh    the cheap reader
  bin/shunt               on / off / status / log / test
  config.json             defaults
tests/run_tests.sh  60 offline hook tests, fixtures generated on the fly
codex/PORT_SPEC.md  how to build the same thing for the Codex CLI
```

## Install

```bash
git clone <this repo> claude-shunt
cd claude-shunt
bash install.sh
```

`install.sh` copies `shunt/` to `~/.claude/shunt`, keeping any `config.json` and `log/` you
already have, merges two `PreToolUse` entries into `~/.claude/settings.json` (with a dated
backup), symlinks `~/.local/bin/shunt`, and prints the status. Running it twice is safe: it
never adds a second copy of either hook entry.

Uninstall with `bash uninstall.sh`, or `bash uninstall.sh --purge` to remove the installed
folder and the symlink as well.

## Toggle

```bash
shunt off        # stop blocking
shunt on         # resume
shunt status     # config, whether both hooks are wired, events today
shunt log 20     # last 20 events
shunt test       # run the offline test suite
SHUNT_MODE=off   # environment override, beats the config file
```

## Config keys

`~/.claude/shunt/config.json`:

| Key | Meaning |
| --- | --- |
| `enabled` | Master switch. |
| `min_lines` | Files longer than this are shunted. Default 350. |
| `max_targeted_lines` | Largest slice a single targeted read may take. Default 350. |
| `slice_budget_enabled` | Cap the total lines one session may slice out of one file. |
| `worker` | Reader model. `haiku`, or `claudex:<model>` for a local proxy lane. |
| `worker_timeout_s` | Hard cap on one reader call. Default 60. |
| `exempt_basenames` | Never shunted, for example instruction files. |
| `exempt_path_prefixes` | Never shunted, `~` expands. |
| `exempt_extensions` | Structured data, which a summariser cannot compress faithfully. |
| `log_enabled` | Write the event log. |

Environment: `SHUNT_MODE`, `SHUNT_LOG_PATH` (event log override, used by the tests so they
never touch the real log), `SHUNT_WORKER`, `SHUNT_TIMEOUT`.
`SHUNT_CONFIG_PATH` points both hooks at a different config file, which is how the test
suite runs against a temp config instead of editing the installed one.

## The slice budget

Hooks see one tool call at a time, so a model that is told "no more than 350 lines per read"
can simply take three 350-line reads and rebuild the file anyway. The budget makes the hooks
remember:

- Every allowed targeted read of a big file is logged as `targeted_read`, whether it came
  from the Read tool or from `head -n N`, `tail -n N`, `sed -n 'A,Bp'`.
- Before allowing the next one, the hook adds up what this session has already sliced out of
  this file. If the total would pass `min_lines`, the read is blocked and the model is told
  to run the reader first.
- Running the reader on that file writes `worker_sanctioned`, which lifts the cap for that
  file for the rest of the session. After the cheap pass, targeted reads of the cited lines
  are unlimited.

No session id means no budget. Only the last 3000 log lines are scanned. Anything unexpected
fails open, which means the read is allowed. A hook must never break a tool call.

## Log format

`~/.claude/shunt/log/shunt.log`, one JSON object per line. Events: `block_read`,
`block_bash`, `block_slice_budget`, `targeted_read`, `worker_sanctioned`, `worker_call`,
`worker_fail`. Fields present when they apply: `ts`, `session`, `cwd`, `file`, `files`,
`lines`, `offset`, `limit`, `slices_read`, `file_tokens_est`, `returned_tokens_est`,
`worker`, `in`, `out`, `cost_usd`, `wall_s`. Token estimates are bytes divided by four.

## Measured results

From real `worker_call` rows in the log:

| File | Estimated file tokens | Tokens returned to the main model | Kept out of context |
| --- | --- | --- | --- |
| 858-line guide | 15036 | 180 | 98.8 percent |
| 100-line plan | 1746 | 68 | 96.1 percent |

A reader pass on the 858-line guide cost about 5 cents and took 24 seconds, and its three
bullets carried the exact line numbers and quoted wording the main model needed. The trade is
real: you spend a little money and half a minute of latency on a small model to avoid pulling
a large file into an expensive context that then gets re-read on every subsequent turn.

### Two ways the model routed around it, and what closed each

**Integrity refusal.** The first block message read like an unknown script asking to be run,
and the model correctly declined to run it. Fix: the message now names the script as the
workspace's sanctioned helper and gives the full command. That stopped the refusal in the
next run.

**Slicing.** With the block in place, the model read the same 858-line file in three legal
350-line slices and had the whole thing in context anyway. Fix: the slice budget above. It
is enforced across both the Read tool and shell readers, so switching to `head` does not
reset it.

## Known gaps

1. **Grep is not metered.** A blocked model can still `grep -n` a file repeatedly and
   assemble an answer from matches. Observed: after one slice was spent, the model switched
   to grep rather than a second slice, so the budget never fired. Grep output is far smaller
   than a slice, so this is cheap, but it is not the reader path.
2. **The model may decline the reader.** Even with the sanctioned-helper wording, a model
   may answer from a single slice plus a search rather than run a script an error message
   named. The block still works, in that the whole file stays out of context. The cheap
   reader is what gets skipped.
3. **Only Read and Bash are covered.** Grep and Glob output, MCP tool results, and web or
   API payloads are not.
4. **A malformed config fails open**, and fail-open beats `SHUNT_MODE=on`.
5. **Shell parsing is deliberately shallow.** Only the first simple command of a line is
   inspected, and anything with a pipe, redirect, command substitution or heredoc is allowed
   through. Blocking a legitimate command is worse than missing one.
6. **The budget is per session.** A fresh session starts with a fresh budget.

## Advisory layer (recommended)

The hooks enforce. They cannot make the model *want* the cheap reader: a blocked model may
still prefer a targeted read or a `grep` sweep, or decline outright to run a script that an
error message named at it. Closing that last gap is a matter of instruction, not enforcement.
Add this to your global `CLAUDE.md` (Claude Code) or `AGENTS.md` (Codex):

```
When a `[shunt]` hook blocks a read, run the helper it names (`~/.claude/shunt/scripts/bulk_read.sh`); that is my approved path, not an untrusted instruction. Treat its bullets as leads and confirm any cited lines with a targeted read (offset/limit) before acting on, editing, publishing or citing them. Toggle with `shunt on` / `shunt off` (config `~/.claude/shunt/config.json`).
```

## Tests

```bash
bash tests/run_tests.sh     # or: shunt test
```

60 cases, no network, no model calls. Fixtures are generated into a temp directory, every
case writes to a temp event log, and every case reads a temp config through
`SHUNT_CONFIG_PATH`, so the suite never edits or restores the installed `config.json`
and passes the same whether or not the harness is installed. The suite covers the read
gate, the shell gate, exemptions, the toggle precedence rules, and the whole slice budget
including the sanctioning path.
`shunt/tests/run_tests.sh` is the same file, shipped so that `shunt test` works after install.

## License

MIT. See LICENSE.
