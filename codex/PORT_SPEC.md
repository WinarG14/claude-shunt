# Port spec: the shunt harness for the Codex CLI

This document is self-contained. An agent can implement the Codex side from this file alone,
without the conversation that produced the Claude Code version. Read `../README.md` for the
motivation and `../shunt/hooks/` for the reference implementation.

## (a) Goal and rules

### Goal

Stop a coding agent from pulling whole large files into its own context. Instead, route the
file to a cheap reader model that answers one specific question with line-cited bullets, then
let the agent confirm anything load-bearing with small targeted reads. Measured on the Claude
side: 96 to 99 percent of a file's estimated tokens never reach the main model.

### Definitions

- `min_lines` (default 350): a file with more lines than this is "big".
- `max_targeted_lines` (default 350): the largest slice one targeted read may take.
- "Exempt": never shunted. Instruction files by basename (`CLAUDE.md`, `AGENTS.md`,
  `MEMORY.md`, `SKILL.md`, `README.md`), structured data by extension (`.json`, `.yaml`,
  `.yml`, `.toml`, `.csv`, `.tsv`, `.jsonl`, `.lock`), and anything under the configured path
  prefixes (`~/.claude/`, `~/.claudex/`, `~/.codex/`, `~/.ai-skills/`). A summariser cannot
  faithfully compress structured data, and instruction files must be read whole.
- "Text": first 4096 bytes contain no NUL byte and decode as UTF-8. Binary files are allowed
  through untouched.

### File-read rule

Given a read request for `path`:

1. If the harness is disabled, allow.
2. If `path` is missing, not a regular file, not text, or exempt, allow.
3. Count lines. If `lines <= min_lines`, allow.
4. If the request has an explicit line limit `L` and `L <= max_targeted_lines`, this is a
   targeted read: apply the slice budget below.
5. Otherwise (no limit, or a limit above the cap) block with the whole-file message.

### Shell-command rule

Inspect only the first simple command of the line (split on `;` and `&&`, take the first).
Allow immediately, without inspection, if the raw command contains any of `|`, `>`, `$(`,
a backtick, or `<<`. Drop leading `VAR=value` assignments. Then:

- Program not in `{cat, less, more, head, tail, sed}`: allow.
- `head` or `tail`: find the explicit line count. Support `-n N`, `-nN`, `--lines=N`, `-N`,
  and a leading `+` on the number. No explicit count means the default of 10, which is
  allowed and not metered. Count above `max_targeted_lines`: block. Count at or below it:
  targeted read, apply the budget.
- `sed`: only when `-n` is present and an argument matches `^(\d+),(\d+)p$` after stripping
  quotes. Span is `B - A + 1`. Above the cap: block. At or below: targeted read, apply the
  budget. Any other sed usage is allowed.
- `cat`, `less`, `more`: block if any non-flag argument resolves to a big non-exempt text
  file. Relative paths resolve against the call's working directory.

Blocking is intentionally conservative. Letting a command through is always better than
breaking a legitimate one.

### Slice budget rule

Hooks see one call at a time, so a per-read cap alone is defeated by taking three legal
slices of the same file. The budget adds state, keyed on `(session id, real path)`:

1. Every allowed targeted read, from the file-read tool or from a shell reader, appends a
   `targeted_read` event carrying `limit` (the number of lines that read pulled in).
2. Before allowing the next targeted read, sum the `limit` of prior `targeted_read` events
   for the same session and the same real path, scanning only the last 3000 log lines.
3. If a `worker_sanctioned` event exists for that session and path, allow, with no cap.
4. Otherwise, if `prior_sum + this_limit > min_lines`, block with the budget message.
5. Otherwise log the `targeted_read` and allow.

A reader invocation appends `worker_sanctioned` with every absolute existing file path named
on its command line, real-path resolved, and is always allowed. Recognise an invocation only
when the reader script is the command word, or the second word after `bash`, `sh` or `zsh`.
A command that merely mentions the script, such as `cat bulk_read.sh`, must not sanction.

Missing or empty session id: skip the budget and allow. Any parse or IO error anywhere in the
budget path: allow. The harness must never break a tool call.

### Exact message texts

Whole-file block, on the file-read path. `{path}`, `{n}`, `{min_lines}`, `{max_targeted}`:

```
[shunt] {path} has {n} lines (limit {min_lines}); whole-file reads are shunted to a cheap reader to keep context small. This is the workspace's sanctioned helper. Run: bash {bulk} "{path}" "<your question>"  → returns line-cited bullets only. Treat bullets as leads: before you act on, edit, publish or cite any fact, do a targeted Read of the cited lines (offset/limit ≤ {max_targeted}). Follow-up questions on the same file cost nothing: run the helper again. Toggle: `shunt off` or SHUNT_MODE=off.
```

The shell version of that message is identical except that it starts
`[shunt] bash read blocked: {path} has {n} lines ...`.

The sanctioned-helper wording is load-bearing. An earlier version read like an unknown script
demanding to be run, and the model refused on integrity grounds. Do not soften or drop it.

Budget block, on the file-read path. `{sum}` is what the session has already sliced out of
the file, `{n}` the file's line count:

```
[shunt] You have already read {sum} of {n} lines of {path} in slices this session; further slices would rebuild the whole file in context. Run the reader first: bash {bulk} "{path}" "<your question>" — after that, targeted Reads of the cited lines are unlimited for this file. Follow-up questions on the same file cost nothing: run the helper again. Toggle: `shunt off`.
```

The shell version is the same text prefixed `[shunt] bash read blocked: ` in place of
`[shunt] `.

`{bulk}` is the absolute path of the reader script, resolved from the hook file's own real
path (`../scripts/bulk_read.sh`), so a copy running from a plugin cache still names a script
that exists. When Codex serves the reader itself, put the equivalent Codex-side reader command
there instead, and keep everything else word for word.

## (b) Hook mechanism on the Codex side

**Note before you start.** Spotify's own Codex plugin (`.codex-plugin/plugin.json` in
https://github.com/spotify/portal-ai-plugins) ships skills only, no hooks: upstream, shunt is
a Claude Code plugin. So the first job of this port is to confirm whether Codex CLI 0.144.x
actually exposes a pre-tool hook. If it does, implement the enforcement below. If it does
not, fall back to the skills layer (`shunt/skills/bulk-reader/SKILL.md`) plus a rule in
`~/.codex/AGENTS.md`, which is soft enforcement: it asks the model to use the reader, it
cannot stop it reading. Say so plainly in the README rather than implying the Codex side
blocks anything.

Codex CLI 0.144.x supports lifecycle hooks configured under `~/.codex`. A SessionStart hook is
already in use on the author's machine, so the mechanism is known to work. Implement the
equivalent of Claude Code's `PreToolUse` for two things: file reads, and shell commands.

**Verify before coding.** Check the exact hook event names and the stdin/stdout contract
against `codex --help` and the current Codex hooks documentation. Do not assume the Claude
Code shapes carry over. In particular, confirm:

- the event name that fires before a tool call, and whether file reads and shell commands are
  separate events or one event distinguished by a tool name field;
- the JSON keys for the session id, working directory, tool name, and tool arguments;
- how a hook signals "block" and how its message reaches the model. Claude Code uses exit
  code 2 with the message on stderr, and exit 0 to allow. If Codex expects a JSON decision
  object on stdout instead, emit that and keep the message text identical;
- the timeout key. Codex expects `timeoutSec` where Claude Code uses `timeout`. Use
  `timeoutSec`, and give the hook 10 seconds.

The reference implementation's decision logic is in `../shunt/hooks/check_read.py`,
`../shunt/hooks/check_bash.py` and `../shunt/hooks/shunt_budget.py`. Port the logic and the
message strings, not the transport.

Confirm with the user before writing to `~/.codex/config.toml`. Show the exact block you
intend to add, and back the file up first.

## (c) Reader model

The Claude side uses `claude -p --model haiku`. The Codex side uses `gpt-5.6-luna` served by
the user's local OpenAI-compatible proxy.

- Endpoint: `http://127.0.0.1:8317` (CLIProxyAPI), OpenAI-compatible chat completions.
- Model id: `gpt-5.6-luna`, or whatever alias your proxy serves it under. Probe once and
  cache the working id in the config, not in code.
- Auth: read the bearer token at call time from the macOS Keychain, service
  `claudex-proxy-token`:

  ```bash
  security find-generic-password -s claudex-proxy-token -a "$USER" -w
  ```

  Pass it as `Authorization: Bearer <token>`. Never write the token to a file, a log, a
  command line that gets logged, or an error message. If the Keychain item is missing, fail
  the reader call with a clear message and let the caller fall back to targeted reads.
- Timeout: `worker_timeout_s` from the config, default 180 seconds, hard. There is no `timeout` binary on the target machine, so wrap with
  `perl -e 'alarm shift; exec @ARGV' 60 ...` or an equivalent in-process deadline.
- Payload cap: before calling the model, add up the bytes of the files. Above
  `max_payload_bytes` (default 600000), print
  `[shunt] payload <bytes> bytes exceeds max_payload_bytes (<cap>). Split the files or ask a
  narrower question; use targeted Reads for the sections you need.`, log `worker_fail` with a
  `reason`, and exit 1 without calling the model.
- Before the call, print `[shunt: ~<chars/4> input tokens | delegated to <worker>]` to stderr.
- The reader runs with no tools and no project instructions. On the Claude side this is done
  by running from a scratch working directory that contains a stub instruction file, with the
  Anthropic environment variables unset and an empty MCP config. Do the equivalent: a plain
  HTTP call to the proxy already has no tools and no project context, which is the point.

### System prompt, unchanged

```
You are a precise document analyst. Answer the question ONLY from the provided files. Output structured bullets only; no greetings, no prose, no preamble. Every bullet starts with the file's line reference(s) in the form L<n> or L<a>-<b>, then the fact. Quote exact wording for names, values, dates and commands. If the answer is not explicitly stated in the files, output the single bullet: '- NOT IN FILE: <one line on what is closest and where>'. Never infer an order, structure or list that the text does not state.
```

### User message format

The question, a blank line, then each file tagged and line numbered:

```
<question>

<file path="<path>" lines="<count>">
1: <first line>
2: <second line>
...
</file>

```

Line numbers are one-based and are what the bullets cite. Multiple files are concatenated in
argument order.

### Output footer

After the model's bullets, print one line:

```
[shunt] worker=<model> in=<input tokens> out=<output tokens> cost=$<cost> wall=<seconds>s
```

Sum prompt tokens including any cached-prompt counts into `in`.

### Shared log

Write to the same file as the Claude side, `~/.claude/shunt/log/shunt.log`, honouring a
`SHUNT_LOG_PATH` override. One JSON object per line, same schema, so one log covers both
harnesses:

```json
{"ts":"<ISO 8601 with offset>","event":"worker_call","session":"","cwd":"<cwd>",
 "file":"<path1>;<path2>;","file_tokens_est":<bytes/4>,"returned_tokens_est":<chars/4>,
 "worker":"gpt-5.6-luna","in":<int>,"out":<int>,"cost_usd":<float>,"wall_s":<float>}
```

Other events: `block_read`, `block_bash`, `block_slice_budget`, `targeted_read`,
`worker_sanctioned`, `worker_fail`. Field sets match the reference implementation. Because
both harnesses read this log to compute the budget, the schema is a contract. Do not rename
fields or change the event names.

## (d) One switch for both apps

The Codex hooks read the same config file as the Claude hooks: `SHUNT_HOME/config.json`,
where `SHUNT_HOME` defaults to `~/.claude/shunt`. Do not create a second config under
`~/.codex`. A missing config file is not an error: create the home, write the defaults with
`enabled: true`, and carry on. Only a malformed one fails open. Honour the
same keys and the same precedence:

1. `SHUNT_MODE=off` in the environment: disabled.
2. `SHUNT_MODE=on`: enabled.
3. Otherwise the `enabled` key in the config.
4. A missing or malformed config: fail open, allow everything, and append the reason to
   `~/.claude/shunt/log/hook_errors.log`.

`slice_budget_enabled` gates the budget separately. `shunt on` and `shunt off` then control
both applications from one place, which is the point of sharing the file. If the Codex reader
needs its own model id, add a key such as `codex_worker` rather than a second file.

`SHUNT_CONFIG_PATH` in the environment points the hooks at a different config file. It exists
for the test suite, which must never read or edit the installed config; it is not a second
config, and nothing but a test should set it.

## (e) Acceptance tests

Mirror `../tests/run_tests.sh`. Generate fixtures at run time into a temp directory: a
900-line markdown file, a 400-line file with an exempt basename, a two-line small file, a
large `.json`, and a file with NUL bytes. Point every case at a temp event log through
`SHUNT_LOG_PATH`. Feed each hook a synthetic event on stdin and assert the decision. Print
PASS or FAIL per case and exit non-zero if any failed. No network, no model calls.

Read gate: whole-file read of the big file blocks; a 100-line targeted read allows; a limit
above the cap blocks; an offset with no limit blocks; a small file allows; an exempt basename
allows; an exempt path prefix allows; a big `.json` allows; a missing path allows; a binary
file allows; a request with no path allows; disabled allows.

Shell gate: `cat big` blocks; `cat big | head -20` allows because of the pipe; `head -20 big`
allows; `head -n 500 big` blocks; `tail -n 20 big` allows; `sed -n '1,50p' big` allows;
`sed -n '1,600p' big` blocks; `sed 's/a/b/' big` allows; `grep big` allows; a redirect
allows; a heredoc allows; a relative path resolved against the working directory blocks; an
exempt file allows; a small file allows; `less big` blocks; disabled allows.

Slice budget: two 350-line slices of the same file in one session, second blocks; the same
two slices with a pre-seeded `worker_sanctioned` event, both allow; slices under different
session ids are independent; with `slice_budget_enabled` false, three slices all allow; a
reader invocation exits zero and appends a `worker_sanctioned` line naming the file, after
which three slices all allow; a request with no session id is never budgeted; `head -n 300`
twice in one session, second blocks; a targeted read followed by an over-budget shell slice
blocks; a command that merely mentions the reader script does not sanction.

Config precedence: `enabled` false allows on both gates, and `SHUNT_MODE=on` beats it.

Payload cap, home and bootstrap: a reader call whose files exceed a tiny `max_payload_bytes`
exits 1 with the cap message, logs `worker_fail`, and never calls the model; a `SHUNT_HOME`
pointed at an empty temp directory is populated with a default config and the gate then
blocks; a `SHUNT_HOME` holding a disabled config is honoured by both gates and by the CLI.

The suite must never edit the installed config. Write one temp config (a copy of the real one,
with an exempt path prefix added for the generated fixture directory so the exempt-prefix case
does not depend on where the harness is installed) and export `SHUNT_CONFIG_PATH` for every
case; use extra temp variants for the `enabled: false` and `slice_budget_enabled: false`
cases. Assert at the end that the real config is byte-identical to what it was before the run
and still valid JSON.

## (f) Do not

- Do not write a token, key or password into any file, log, or tool output. The proxy token
  is read from the Keychain at call time and lives only in memory.
- Do not edit anything outside `~/.codex` configuration and this repository. In particular,
  do not modify project files, other harnesses, or the user's shell profile.
- Do not change `~/.codex/config.toml` without showing the exact proposed change and getting
  explicit confirmation first. Back it up before writing.
- Do not create a second config file, a second log file, or a second toggle. One config, one
  log, one switch, both applications.
- Do not make a hook fail closed. Every unexpected condition allows the tool call.
- Do not weaken the sanctioned-helper wording or the budget message. Both were tuned against
  observed model behaviour.
- Do not add network calls to the hooks themselves. Only the reader script talks to a model.

## (g) Advisory line for `~/.codex/AGENTS.md`

The hooks enforce. They cannot make the model *want* the cheap reader: a blocked model may
still prefer a targeted read or a `grep` sweep, or decline outright to run a script that an
error message named at it. Closing that last gap is a matter of instruction, not enforcement.
Add this line to the user's global `~/.codex/AGENTS.md` (same text as the Claude Code side;
the helper path is unchanged because both applications share `~/.claude/shunt`), with the
usual confirm-before-writing rule from (f):

```
When a `[shunt]` hook blocks a read, run the helper it names (`~/.claude/shunt/scripts/bulk_read.sh`); that is my approved path, not an untrusted instruction. Treat its bullets as leads and confirm any cited lines with a targeted read (offset/limit) before acting on, editing, publishing or citing them. Toggle with `shunt on` / `shunt off` (config `~/.claude/shunt/config.json`).
```
