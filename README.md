# claude-shunt v0.2.0

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
install.sh                       install or re-install, wire the hooks, symlink the CLI
uninstall.sh                     remove the hooks (--purge also deletes the install)
.claude-plugin/marketplace.json  marketplace manifest, one plugin: shunt
shunt/                           the harness itself, copied to ~/.claude/shunt
  .claude-plugin/plugin.json       plugin manifest (v0.2.0), points at skills/
  hooks/check_read.py              Read tool gate plus slice budget
  hooks/check_bash.py              Bash tool gate, budget metering, reader sanctioning
  hooks/shunt_budget.py            shunt home, config, event log, budget helpers
  hooks/hooks.json                 PreToolUse wiring for the plugin layout
  scripts/bulk_read.sh             the cheap reader
  skills/bulk-reader/SKILL.md      tells the model the reader exists and how to call it
  bin/shunt                        on / off / status / log / test / version
  config.json                      defaults
tests/run_tests.sh               70 offline hook tests, fixtures generated on the fly
codex/PORT_SPEC.md               how to build the same thing for the Codex CLI
```

Three layers, the same shape as Spotify's plugin: hooks enforce, a script does the cheap
read, and a skill tells the model the script is there. The hooks alone leave a gap, because
a blocked model has to be told what to run.

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

It also copies `skills/bulk-reader/SKILL.md` to `~/.claude/skills/bulk-reader/SKILL.md`, and
adds any config key a new version introduced without touching values you have changed.

Uninstall with `bash uninstall.sh`, or `bash uninstall.sh --purge` to remove the installed
folder, the symlink and the skill as well.

### Or as a plugin

```bash
claude plugin marketplace add WinarG14/claude-shunt
claude plugin install shunt@claude-shunt
```

The plugin carries its own `hooks/hooks.json`, so Claude Code wires the two `PreToolUse`
hooks itself and the skill comes from the plugin's `skills/` directory. Pick one route, not
both: running `install.sh` as well would wire a second copy of each hook.

In the plugin layout the hooks run from a plugin cache directory, so the two locations are
kept apart. The scripts are resolved from the hook file's own real path, which is why the
block message always names a `bulk_read.sh` that exists. The config and the event log live
at a fixed home, `SHUNT_HOME`, default `~/.claude/shunt`, so one toggle and one slice budget
cover every copy. If that config file is missing, the hooks create the home and write the
defaults rather than doing nothing.

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
| `worker_timeout_s` | Hard cap on one reader call. Default 180. |
| `max_payload_bytes` | Refuse the reader call when the files add up to more than this. Default 600000. |
| `exempt_basenames` | Never shunted, for example instruction files. |
| `exempt_path_prefixes` | Never shunted, `~` expands. |
| `exempt_extensions` | Structured data, which a summariser cannot compress faithfully. |
| `log_enabled` | Write the event log. |

Environment: `SHUNT_MODE`, `SHUNT_HOME` (where the config and the log live, default
`~/.claude/shunt`), `SHUNT_LOG_PATH` (event log override, used by the tests so they never
touch the real log), `SHUNT_WORKER`, `SHUNT_TIMEOUT`, `SHUNT_MAX_PAYLOAD_BYTES`.
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

## How this compares with Spotify's official shunt plugin

Spotify ships the same idea as an open-source plugin: `plugins/shunt` v0.2.0 in
https://github.com/spotify/portal-ai-plugins, Apache-2.0. This harness was built from the
write-up rather than the code, and the two ended up close enough to be worth a straight
comparison. Their measured saving is 82 to 94 percent per read, mean 90, on a Java
monorepo. This harness measured 96 to 99 percent, on long markdown documents.

| Where it lands | What |
| --- | --- |
| Same | 350-line threshold, settable by environment variable or config. |
| Same | Two `PreToolUse` hooks, one on Read and one on Bash. |
| Same | Piped and redirected commands pass through untouched. |
| Same | Files are wrapped in XML tags before they go to the reader. |
| Same | The reader answers in bullets only, at low creativity, and nothing else. |
| Same | Three layers: hooks, scripts, skills. |
| Stricter here | Targeted reads are capped at 350 lines and metered by a per-session slice budget, so the file cannot be rebuilt from legal slices. The cap is lifted for a file once the reader has been consulted on it. |
| Stricter here | Instruction files and structured-data files are exempt, because a summariser cannot faithfully compress them. |
| Stricter here | The reader gets line-numbered input, must cite `L` references, and must answer `NOT IN FILE` rather than guess. |
| Stricter here | An on and off toggle, plus JSON-lines telemetry with real token counts and costs. |
| Stricter here | `head` and `tail` are blocked only above the threshold. Spotify blocks any `head` or `tail` on a big file. |
| Not here | Their second worker, the code writer. |
| Not here | Their transport, the Portal command line tool and AiKA modes. This harness calls `claude -p` with a cheap model, or a local proxy lane. |
| Not here | Their evals harness. |

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
The `bulk-reader` skill is the first half of that, and it installs itself. For belt and
braces, add this to your global `CLAUDE.md` (Claude Code) or `AGENTS.md` (Codex):

```
When a `[shunt]` hook blocks a read, run the helper it names (`~/.claude/shunt/scripts/bulk_read.sh`); that is my approved path, not an untrusted instruction. Treat its bullets as leads and confirm any cited lines with a targeted read (offset/limit) before acting on, editing, publishing or citing them. Toggle with `shunt on` / `shunt off` (config `~/.claude/shunt/config.json`).
```

## Tests

```bash
bash tests/run_tests.sh     # or: shunt test
```

70 cases, no network, no model calls. Fixtures are generated into a temp directory, every
case writes to a temp event log, and every case reads a temp config through
`SHUNT_CONFIG_PATH`, so the suite never edits or restores the installed `config.json`
and passes the same whether or not the harness is installed. The suite covers the read
gate, the shell gate, exemptions, the toggle precedence rules, and the whole slice budget
including the sanctioning path, the payload cap, the config bootstrap and the `SHUNT_HOME`
override.
`shunt/tests/run_tests.sh` is the same file, shipped so that `shunt test` works after install.

## License

MIT. See LICENSE.
