# Codex Desktop global shunt

Codex adapter for `claude-shunt` v0.2.0, upstream commit
`dacb48396d21d03c8083914d2aaecf207595b16a`.

## Installed behavior

- PreToolUse checks supported local file reads and simple shell readers. Large
  non-exempt text files are redirected to the Luna reader; targeted slices share
  the upstream per-session budget.
- A tool-free HTTP request sends only the named files and question to the existing
  local proxy at `http://127.0.0.1:8317/v1/chat/completions`. That proxy routes to
  its configured model provider; local transport does not mean local inference.
- Model: `codex_worker` in `~/.claude/shunt/config.json`, default `gpt-5.6-luna`.
  `SHUNT_CODEX_WORKER` overrides it. Claude's `worker` remains `haiku`.
- Token: macOS Keychain service `claudex-proxy-token`, account = current username.
  The reader retrieves it at call time, keeps it in memory, disables redirects
  and environment HTTP proxies, and never prints raw HTTP error bodies.
- Config, event log and `shunt on` / `shunt off` are shared with Claude.
  Disabling stops the gates and advisory routing, not an explicitly invoked reader.
- Output is untrusted evidence-finding assistance. Verify important cited lines.
  Follow-up calls may incur charges. Missing cost data is reported as `unknown`,
  not zero. Chat Completions prompt token counts already include cached tokens.

## Installation

This installer targets the existing macOS shared-skill setup: Claude shunt and
`bulk-reader` must already be installed. It does not install or change the proxy.

```bash
python3 codex/install.py   # from the repo root
```

It installs files under `~/.codex/shunt`, merges one PreToolUse entry into
`~/.codex/hooks.json`, adds the Codex global advisory rule, adds `codex_worker`
without altering existing shared config values, and updates the canonical shared
skill with separate Codex and Claude commands. Reinstallation is idempotent.
It never writes `~/.codex/config.toml`, replaces Claude hooks or its reader,
changes the shell profile, or updates proxy configuration.

Modified files are backed up under
`~/.local/state/claude-shunt/backups/<timestamp>/`, retaining paths relative to HOME.

**Activation requires user review.** Open Codex hook settings or `/hooks` in the
terminal interface and trust the hook named **Shunt: checking large-file read**.
Do not use a trust-bypass option. Open a fresh Codex task after approval. A parsed,
enabled hook with `trustStatus: untrusted` does not enforce anything yet.

The hook command is:

```bash
python3 "$HOME/.codex/shunt/hooks/pre_tool_use.py"
```

Use the reader manually:

```bash
bash "$HOME/.codex/shunt/scripts/bulk_read.sh" "/absolute/file.md" "What does this file say about X?"
```

## Verification on 2026-09-06

- Desktop bundled runtime: `codex-cli 0.153.3`; shell CLI: `0.144.4`.
- Desktop app-server `hooks/list` parsed the installed hook with no errors or
  warnings, matcher `^(Bash|Read|read_file|exec_command|shell_command)$`, timeout
  10 seconds. At installation the new hook was **untrusted**, so actual
  model-driven blocking remains unverified pending the user's trust approval.
- 70 upstream offline cases passed. 11 Codex tests passed both from source and
  the installed directory. They exercise denial JSON, tool argument normalization,
  cross-tool budget, reader sanctioning, disabled/malformed config, fail-open,
  payload bounds, no-call on overflow, token accounting, unknown costs, truncation
  rejection and sanitized error handling.
- Two live synthetic reader tests passed through `gpt-5.6-luna`: a short file
  returned the exact marker at line 3, and the installed reader returned the exact
  owner and approval code at line 472 of a 900-line file (7704 input tokens,
  38 output tokens, 2.2 seconds; cost unavailable). The cited line was checked
  directly. No company documents were used for smoke testing.
- Installing twice left exactly one PreToolUse group. Existing SessionStart
  configuration and pre-existing shared config values were preserved.

```bash
python3 -m unittest discover -s codex/tests -v   # from the repo root
bash tests/run_tests.sh
```

## Limits

This is a context guardrail, not a security sandbox. It inherits upstream's
conservative shell parser: pipes, redirects, substitutions, arbitrary programs,
other readers, and commands after the first simple command are not enforced.
MCP and hosted results are not covered. Existing interactive shell input is not
rechecked by PreToolUse. The upstream sanction marks reader invocation, not proof
of worker success, and budget updates are not atomic across concurrent calls.
Unknown events and parsing failures allow the tool to continue.

The installer preserves the existing SessionStart hook as requested. Runtime
inspection showed that separate pre-existing hook was also untrusted and its
`timeoutSec` configuration was interpreted as the default 600 seconds. This
adapter uses the documented `timeout: 10`; it does not repair unrelated hooks.

## Rollback

For an immediate global pause, use `shunt off` (also pauses Claude shunting).
To remove only Codex enforcement, remove the single PreToolUse entry whose command
is the Codex shunt adapter from `~/.codex/hooks.json`. Remove the
`Shunt large-file reader (Codex)` section from `~/.codex/AGENTS.md`, and remove the
Codex routing branch from the canonical bulk-reader skill. Keep the Claude branch.
Remove only the `codex_worker` key from shared config. After checking there are no
remaining references, `~/.codex/shunt` can be removed. Do not blindly restore old
backups over unrelated changes made after installation.

## Sources and port-spec corrections

- https://github.com/WinarG14/claude-shunt
- https://developers.openai.com/codex/hooks/
- https://developers.openai.com/codex/skills/

Current hook documentation supports PreToolUse, maps unified exec to `Bash`, uses
`tool_input.command`, and accepts JSON denial or exit 2. The adapter returns JSON
denial. Current documented configuration uses `timeout`, not the older port spec's
`timeoutSec`. Runtime `hooks/list` returns the resolved value as `timeoutSec`.
The port spec's free-follow-up and zero-default-cost language is not retained.
