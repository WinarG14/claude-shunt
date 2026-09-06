#!/usr/bin/env python3
"""Shared helpers for the shunt PreToolUse hooks: the shunt home, the config
file, the event log, and the slice budget.

Two locations matter, and they are deliberately separate:

* the SCRIPT location - wherever this file happens to live (a normal install
  under ~/.claude/shunt, or a plugin cache directory when the harness is
  installed as a Claude Code plugin). Hooks resolve `scripts/bulk_read.sh`
  relative to their own realpath, so the redirect message always names a
  script that exists.
* the HOME location - `SHUNT_HOME`, default `~/.claude/shunt`. The config file
  and the event log live here in both layouts, so one toggle and one budget
  cover every copy of the harness.

A "slice budget" makes the otherwise stateless hooks stateful: every ALLOWED
targeted read of a big file is written to the event log as `targeted_read`, and
once the slices for one (session, file) would add up to more than `min_lines`
the next slice is blocked until the cheap reader has been run for that file
(a `worker_sanctioned` event, written by check_bash.py).

Never raises, except where a caller explicitly handles it: callers treat an
exception as fail-open (allow).
"""
import datetime
import json
import os

TAIL_LINES = 3000
DEFAULT_HOME = "~/.claude/shunt"

# Written to SHUNT_HOME/config.json when no config file is there yet.
DEFAULT_CONFIG = {
    "enabled": True,
    "min_lines": 350,
    "max_targeted_lines": 350,
    "slice_budget_enabled": True,
    "worker": "haiku",
    "worker_timeout_s": 180,
    "max_payload_bytes": 600000,
    "exempt_basenames": [
        "CLAUDE.md",
        "AGENTS.md",
        "MEMORY.md",
        "SKILL.md",
        "README.md",
    ],
    "exempt_path_prefixes": [
        "~/.claude/",
        "~/.claudex/",
        "~/.codex/",
        "~/.ai-skills/",
    ],
    "exempt_extensions": [
        ".json",
        ".yaml",
        ".yml",
        ".toml",
        ".csv",
        ".tsv",
        ".jsonl",
        ".lock",
    ],
    "log_enabled": True,
}

BUDGET_MSG = (
    "You have already read {sum} of {n} lines of {path} in slices this session; "
    "further slices would rebuild the whole file in context. "
    'Run the reader first: bash {bulk} "{path}" "<your question>" — after that, '
    "targeted Reads of the cited lines are unlimited for this file. "
    "Follow-up questions on the same file cost nothing: run the helper again. "
    "Toggle: `shunt off`."
)


def home():
    """The shunt home: config file and event log. `SHUNT_HOME` overrides."""
    override = (os.environ.get("SHUNT_HOME") or "").strip()
    return os.path.expanduser(override or DEFAULT_HOME)


def config_path():
    """Config file path. `SHUNT_CONFIG_PATH` overrides it, so the tests never
    read or write the installed config.json."""
    override = (os.environ.get("SHUNT_CONFIG_PATH") or "").strip()
    if override:
        return os.path.expanduser(override)
    return os.path.join(home(), "config.json")


def errlog_path():
    return os.path.join(home(), "log", "hook_errors.log")


def evlog_path():
    """Event-log path. SHUNT_LOG_PATH overrides, so tests never touch the real log."""
    override = (os.environ.get("SHUNT_LOG_PATH") or "").strip()
    if override:
        return os.path.expanduser(override)
    return os.path.join(home(), "log", "shunt.log")


def write_default_config(path):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
        os.makedirs(os.path.join(os.path.dirname(path), "log"), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(DEFAULT_CONFIG, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    return dict(DEFAULT_CONFIG)


def load_config():
    """Return (config, note).

    Missing config: create the home, write the defaults, and carry on, so a
    plugin install with no `install.sh` run still works. Malformed config:
    (None, note) and the caller fails open. `note` is a string to log, or None.
    """
    path = config_path()
    if not os.path.exists(path):
        try:
            return write_default_config(path), "wrote default config to %s" % path
        except Exception as exc:
            return dict(DEFAULT_CONFIG), (
                "could not write default config to %s (%r); using built-in defaults"
                % (path, exc)
            )
    try:
        with open(path) as fh:
            cfg = json.load(fh)
        if not isinstance(cfg, dict):
            raise ValueError("config root is not an object")
        return cfg, None
    except Exception as exc:
        return None, "config %s unreadable, failing open: %r" % (path, exc)


def realpath(p):
    try:
        return os.path.realpath(os.path.expanduser(p))
    except Exception:
        return p


def append_event(cfg, obj):
    if not (cfg or {}).get("log_enabled", True):
        return
    path = evlog_path()
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    obj = dict(obj)
    obj["ts"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    with open(path, "a") as fh:
        fh.write(json.dumps(obj, ensure_ascii=False) + "\n")


def _tail_events():
    path = evlog_path()
    if not os.path.exists(path):
        return []
    with open(path, "r", errors="replace") as fh:
        lines = fh.readlines()[-TAIL_LINES:]
    out = []
    for line in lines:
        line = line.strip()
        if not line or line[0] != "{":
            continue
        try:
            out.append(json.loads(line))
        except Exception:
            continue
    return out


def budget_state(session, target_real):
    """(lines already read in slices, reader-was-consulted) for one session+file."""
    total = 0
    sanctioned = False
    for rec in _tail_events():
        if rec.get("session") != session:
            continue
        ev = rec.get("event")
        if ev == "targeted_read":
            if realpath(str(rec.get("file", ""))) != target_real:
                continue
            try:
                total += int(rec.get("limit") or 0)
            except Exception:
                pass
        elif ev == "worker_sanctioned":
            files = rec.get("files") or []
            if isinstance(files, str):
                files = [files]
            for f in files:
                if realpath(str(f)) == target_real:
                    sanctioned = True
                    break
    return total, sanctioned


def budget_enabled(cfg):
    return bool((cfg or {}).get("slice_budget_enabled", True))


def budget_message(prior_sum, n, path, bulk):
    return BUDGET_MSG.format(sum=prior_sum, n=n, path=path, bulk=bulk)
