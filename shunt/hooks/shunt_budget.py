#!/usr/bin/env python3
"""Shared slice-budget helpers for the shunt PreToolUse hooks.

A "slice budget" makes the otherwise stateless hooks stateful: every ALLOWED
targeted read of a big file is written to the event log as `targeted_read`, and
once the slices for one (session, file) would add up to more than `min_lines`
the next slice is blocked until the cheap reader has been run for that file
(a `worker_sanctioned` event, written by check_bash.py).

Never raises: callers treat an exception as fail-open (allow).
"""
import datetime
import json
import os

TAIL_LINES = 3000

BUDGET_MSG = (
    "You have already read {sum} of {n} lines of {path} in slices this session; "
    "further slices would rebuild the whole file in context. "
    "Run the reader first: bash ~/.claude/shunt/scripts/bulk_read.sh "
    '"{path}" "<your question>" — after that, targeted Reads of the cited '
    "lines are unlimited for this file. Toggle: `shunt off`."
)


def evlog_path(root):
    """Event-log path. SHUNT_LOG_PATH overrides, so tests never touch the real log."""
    override = (os.environ.get("SHUNT_LOG_PATH") or "").strip()
    if override:
        return os.path.expanduser(override)
    return os.path.join(root, "log", "shunt.log")


def realpath(p):
    try:
        return os.path.realpath(os.path.expanduser(p))
    except Exception:
        return p


def append_event(cfg, root, obj):
    if not (cfg or {}).get("log_enabled", True):
        return
    path = evlog_path(root)
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    obj = dict(obj)
    obj["ts"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    with open(path, "a") as fh:
        fh.write(json.dumps(obj, ensure_ascii=False) + "\n")


def _tail_events(root):
    path = evlog_path(root)
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


def budget_state(root, session, target_real):
    """(lines already read in slices, reader-was-consulted) for one session+file."""
    total = 0
    sanctioned = False
    for rec in _tail_events(root):
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


def budget_message(prior_sum, n, path):
    return BUDGET_MSG.format(sum=prior_sum, n=n, path=path)
