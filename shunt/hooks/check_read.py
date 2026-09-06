#!/usr/bin/env python3
"""PreToolUse hook for the Read tool: shunt whole-file reads of large text files.

Exit 0 = allow. Exit 2 = block (stderr text is shown to Claude).
Never crash a tool call: any exception -> log to log/hook_errors.log and exit 0.
"""
import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# The scripts ship beside the hooks, wherever this copy lives (a normal install
# or a plugin cache directory), so resolve them from this file's own realpath.
SCRIPT_ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
BULK = os.path.join(SCRIPT_ROOT, "scripts", "bulk_read.sh")

if HERE not in sys.path:
    sys.path.insert(0, HERE)
import shunt_budget  # noqa: E402

MSG = (
    "[shunt] {path} has {n} lines (limit {min_lines}); whole-file reads are shunted to a "
    "cheap reader to keep context small. This is the workspace's sanctioned helper. "
    'Run: bash {bulk} "{path}" "<your question>"  '
    "→ returns line-cited bullets only. Treat bullets as leads: before you act on, "
    "edit, publish or cite any fact, do a targeted Read of the cited lines "
    "(offset/limit ≤ {max_targeted}). Follow-up questions on the same file cost "
    "nothing: run the helper again. Toggle: `shunt off` or SHUNT_MODE=off."
)


def log_error(msg):
    try:
        errlog = shunt_budget.errlog_path()
        os.makedirs(os.path.dirname(errlog), exist_ok=True)
        with open(errlog, "a") as fh:
            fh.write("%s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), msg))
    except Exception:
        pass


def log_event(cfg, obj):
    try:
        shunt_budget.append_event(cfg, obj)
    except Exception as exc:
        log_error("check_read.py log_event: %r" % (exc,))


def load_config():
    """Config from SHUNT_HOME (default ~/.claude/shunt). A missing config is
    created with the defaults; a malformed one returns None (fail open)."""
    cfg, note = shunt_budget.load_config()
    if note:
        log_error("check_read.py " + note)
    return cfg


def expand(p):
    return os.path.expanduser(p)


def count_lines(path):
    n = 0
    with open(path, "rb") as fh:
        for _ in fh:
            n += 1
    return n


def is_probably_text(path):
    try:
        with open(path, "rb") as fh:
            chunk = fh.read(4096)
        if b"\x00" in chunk:
            return False
        chunk.decode("utf-8")
        return True
    except Exception:
        return False


def is_exempt(cfg, path):
    base = os.path.basename(path)
    if base in (cfg.get("exempt_basenames") or []):
        return "basename"
    _, ext = os.path.splitext(base)
    if ext.lower() in [e.lower() for e in (cfg.get("exempt_extensions") or [])]:
        return "extension"
    rp = os.path.realpath(path)
    for pref in cfg.get("exempt_path_prefixes") or []:
        pe = expand(pref)
        if path.startswith(pe) or rp.startswith(os.path.realpath(pe.rstrip("/")) + "/"):
            return "prefix"
    return None


def enabled(cfg):
    mode = (os.environ.get("SHUNT_MODE") or "").strip().lower()
    if mode == "off":
        return False
    if mode == "on":
        return True
    return bool(cfg.get("enabled", False))


def targeted(cfg, data, path, n, offset, limit, min_lines):
    """Slice budget for an otherwise-allowed targeted read. Fails open."""
    try:
        if not shunt_budget.budget_enabled(cfg):
            return 0
        session = str(data.get("session_id") or "").strip()
        if not session:
            return 0
        real = shunt_budget.realpath(path)
        prior, sanctioned = shunt_budget.budget_state(session, real)
        record = {
            "event": "targeted_read",
            "session": session,
            "cwd": data.get("cwd") or "",
            "file": real,
            "offset": offset,
            "limit": limit,
            "lines": n,
        }
        if not sanctioned and prior + limit > min_lines:
            sys.stderr.write(
                "[shunt] " + shunt_budget.budget_message(prior, n, path, BULK) + "\n"
            )
            log_event(cfg, {
                "event": "block_slice_budget",
                "session": session,
                "cwd": data.get("cwd") or "",
                "file": real,
                "lines": n,
                "slices_read": prior,
                "limit": limit,
            })
            return 2
        log_event(cfg, record)
        return 0
    except Exception as exc:
        log_error("check_read.py budget, failing open: %r" % (exc,))
        return 0


def main():
    raw = sys.stdin.read()
    data = json.loads(raw) if raw.strip() else {}
    cfg = load_config()
    if cfg is None:
        return 0
    if not enabled(cfg):
        return 0

    min_lines = int(cfg.get("min_lines", 350))
    max_targeted = int(cfg.get("max_targeted_lines", 350))

    ti = data.get("tool_input") or {}
    path = ti.get("file_path")
    if not path or not isinstance(path, str):
        return 0
    path = expand(path)
    if not os.path.isfile(path):
        return 0
    if not is_probably_text(path):
        return 0
    if is_exempt(cfg, path):
        return 0

    n = count_lines(path)
    if n <= min_lines:
        return 0

    offset = ti.get("offset")
    limit = ti.get("limit")
    if limit is not None:
        try:
            lim = int(limit)
        except Exception:
            lim = None
        if lim is not None and lim <= max_targeted:
            return targeted(cfg, data, path, n, offset, lim, min_lines)
    # limit absent (with or without offset), or limit > max_targeted -> block

    msg = MSG.format(path=path, n=n, min_lines=min_lines, max_targeted=max_targeted,
                     bulk=BULK)
    sys.stderr.write(msg + "\n")
    try:
        size = os.path.getsize(path)
    except Exception:
        size = 0
    log_event(cfg, {
        "event": "block_read",
        "session": data.get("session_id") or "",
        "cwd": data.get("cwd") or "",
        "file": path,
        "lines": n,
        "file_tokens_est": size // 4,
    })
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # never break the tool call
        log_error("check_read.py: %r" % (exc,))
        sys.exit(0)
