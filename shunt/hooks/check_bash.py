#!/usr/bin/env python3
"""PreToolUse hook for the Bash tool: shunt cat/less/more/head/tail/sed dumps of
large text files. Fails open on anything hard to parse (pipes, redirects,
substitutions, heredocs).

Also carries the slice budget: an allowed `head -n N` / `tail -n N` /
`sed -n 'A,Bp'` on a big file counts toward the same per-session, per-file
budget as a targeted Read, and a `bulk_read.sh` invocation lifts that budget
for the files named in it.

Exit 0 = allow. Exit 2 = block (stderr text is shown to Claude).
Never crash a tool call: any exception -> log to log/hook_errors.log and exit 0.
"""
import datetime
import json
import os
import re
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_CONFIG = os.path.join(ROOT, "config.json")
ERRLOG = os.path.join(ROOT, "log", "hook_errors.log")

if HERE not in sys.path:
    sys.path.insert(0, HERE)
import shunt_budget  # noqa: E402

READERS = {"cat", "less", "more", "head", "tail", "sed"}
HARD = ["|", ">", "$(", "`", "<<"]
SED_RANGE = re.compile(r"^(\d+),(\d+)p$")
WORKER_SCRIPT = "bulk_read.sh"

MSG = (
    "[shunt] bash read blocked: {path} has {n} lines (limit {min_lines}); whole-file reads "
    "are shunted to a cheap reader to keep context small. This is the workspace's sanctioned "
    'helper. Run: bash ~/.claude/shunt/scripts/bulk_read.sh "{path}" "<your question>"  '
    "→ returns line-cited bullets only. Treat bullets as leads: before you act on, "
    "edit, publish or cite any fact, do a targeted Read of the cited lines "
    "(offset/limit ≤ {max_targeted}). Toggle: `shunt off` or SHUNT_MODE=off."
)


def log_error(msg):
    try:
        os.makedirs(os.path.dirname(ERRLOG), exist_ok=True)
        with open(ERRLOG, "a") as fh:
            fh.write("%s %s\n" % (datetime.datetime.now().isoformat(timespec="seconds"), msg))
    except Exception:
        pass


def log_event(cfg, obj):
    try:
        shunt_budget.append_event(cfg, ROOT, obj)
    except Exception as exc:
        log_error("check_bash.py log_event: %r" % (exc,))


def config_path():
    """Config file path. SHUNT_CONFIG_PATH overrides it, so the tests never read or
    write the installed config.json."""
    override = (os.environ.get("SHUNT_CONFIG_PATH") or "").strip()
    if override:
        return os.path.expanduser(override)
    return DEFAULT_CONFIG


def load_config():
    try:
        with open(config_path()) as fh:
            cfg = json.load(fh)
        if not isinstance(cfg, dict):
            raise ValueError("config root is not an object")
        return cfg
    except Exception as exc:
        log_error("check_bash.py config unreadable, failing open: %r" % (exc,))
        return None


def enabled(cfg):
    mode = (os.environ.get("SHUNT_MODE") or "").strip().lower()
    if mode == "off":
        return False
    if mode == "on":
        return True
    return bool(cfg.get("enabled", False))


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
        return True
    _, ext = os.path.splitext(base)
    if ext.lower() in [e.lower() for e in (cfg.get("exempt_extensions") or [])]:
        return True
    rp = os.path.realpath(path)
    for pref in cfg.get("exempt_path_prefixes") or []:
        pe = os.path.expanduser(pref)
        if path.startswith(pe) or rp.startswith(os.path.realpath(pe.rstrip("/")) + "/"):
            return True
    return False


def first_simple_command(cmd):
    """Return the first simple command of a compound line."""
    for sep in (";", "&&"):
        cmd = cmd.split(sep)[0]
    return cmd.strip()


def head_tail_n(args):
    """Explicit line count for head/tail, or None when the default (10) applies."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-n" or a == "-c":
            if a == "-n" and i + 1 < len(args) and args[i + 1].lstrip("+").isdigit():
                return int(args[i + 1].lstrip("+")), {i, i + 1}
            i += 2
            continue
        if a.startswith("--lines="):
            v = a.split("=", 1)[1].lstrip("+")
            if v.isdigit():
                return int(v), {i}
        if a.startswith("-n") and a[2:].lstrip("+").isdigit():
            return int(a[2:].lstrip("+")), {i}
        if re.match(r"^-\+?\d+$", a):
            return int(a.lstrip("-+")), {i}
        i += 1
    return None, set()


def qualifying_files(cfg, args, skip_idx, cwd, min_lines):
    out = []
    for i, a in enumerate(args):
        if i in skip_idx or a.startswith("-"):
            continue
        cand = a if os.path.isabs(a) else os.path.join(cwd, a)
        cand = os.path.expanduser(cand)
        if not os.path.isfile(cand):
            continue
        if not is_probably_text(cand):
            continue
        if is_exempt(cfg, cand):
            continue
        n = count_lines(cand)
        if n > min_lines:
            out.append((cand, n))
    return out


def sanction(cfg, data, cmd):
    """A bulk_read.sh call lifts the slice budget for the files it names.

    Returns True when the command was recognised as a reader invocation
    (in which case the Bash call is always allowed)."""
    try:
        try:
            toks = shlex.split(first_simple_command(cmd))
        except ValueError:
            return False
        if not toks:
            return False
        # an actual invocation: `bulk_read.sh ...` or `bash bulk_read.sh ...`,
        # not a command that merely mentions the script (e.g. `cat bulk_read.sh`)
        invoked = os.path.basename(toks[0]) == WORKER_SCRIPT or (
            len(toks) > 1
            and os.path.basename(toks[0]) in ("bash", "sh", "zsh")
            and os.path.basename(toks[1]) == WORKER_SCRIPT
        )
        if not invoked:
            return False
        files = []
        for t in toks:
            if os.path.basename(t) == WORKER_SCRIPT:
                continue
            p = os.path.expanduser(t)
            if not os.path.isabs(p):
                continue
            if not os.path.isfile(p):
                continue
            rp = shunt_budget.realpath(p)
            if rp not in files:
                files.append(rp)
        log_event(cfg, {
            "event": "worker_sanctioned",
            "session": str(data.get("session_id") or ""),
            "cwd": data.get("cwd") or "",
            "files": files,
        })
        return True
    except Exception as exc:
        log_error("check_bash.py sanction, failing open: %r" % (exc,))
        return True


def targeted(cfg, data, hits, count, min_lines):
    """Slice budget for an allowed targeted bash read. Fails open."""
    try:
        if not hits:
            return 0
        if not shunt_budget.budget_enabled(cfg):
            return 0
        session = str(data.get("session_id") or "").strip()
        if not session:
            return 0
        cwd = data.get("cwd") or ""
        for path, n in hits:
            real = shunt_budget.realpath(path)
            prior, sanctioned = shunt_budget.budget_state(ROOT, session, real)
            if not sanctioned and prior + count > min_lines:
                sys.stderr.write(
                    "[shunt] bash read blocked: "
                    + shunt_budget.budget_message(prior, n, path) + "\n"
                )
                log_event(cfg, {
                    "event": "block_slice_budget",
                    "session": session, "cwd": cwd, "file": real,
                    "lines": n, "slices_read": prior, "limit": count,
                })
                return 2
        for path, n in hits:
            log_event(cfg, {
                "event": "targeted_read",
                "session": session, "cwd": cwd,
                "file": shunt_budget.realpath(path),
                "offset": None, "limit": count, "lines": n,
            })
        return 0
    except Exception as exc:
        log_error("check_bash.py budget, failing open: %r" % (exc,))
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
    cmd = (ti.get("command") or "").strip()
    cwd = data.get("cwd") or os.getcwd()
    if not cmd:
        return 0
    # checked before the fail-open tokens: a reader call must always sanction
    if sanction(cfg, data, cmd):
        return 0
    for tok in HARD:
        if tok in cmd:
            return 0

    seg = first_simple_command(cmd)
    if not seg:
        return 0
    try:
        parts = shlex.split(seg)
    except ValueError:
        return 0
    # drop leading VAR=value assignments
    while parts and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", parts[0]):
        parts = parts[1:]
    if not parts:
        return 0

    prog = os.path.basename(parts[0])
    if prog not in READERS:
        return 0
    args = parts[1:]
    skip = set()

    if prog in ("head", "tail"):
        n, skip = head_tail_n(args)
        if n is None:
            return 0
        if n <= max_targeted:
            return targeted(
                cfg, data, qualifying_files(cfg, args, skip, cwd, min_lines), n, min_lines
            )
    elif prog == "sed":
        if "-n" not in args:
            return 0
        span = None
        for i, a in enumerate(args):
            m = SED_RANGE.match(a.strip("'\""))
            if m:
                span = int(m.group(2)) - int(m.group(1)) + 1
                skip = {i}
                break
        if span is None:
            return 0
        skip |= {i for i, a in enumerate(args) if a == "-n"}
        if span <= max_targeted:
            return targeted(
                cfg, data, qualifying_files(cfg, args, skip, cwd, min_lines), span, min_lines
            )

    hits = qualifying_files(cfg, args, skip, cwd, min_lines)
    if not hits:
        return 0

    path, n = hits[0]
    sys.stderr.write(
        MSG.format(path=path, n=n, min_lines=min_lines, max_targeted=max_targeted) + "\n"
    )
    try:
        size = os.path.getsize(path)
    except Exception:
        size = 0
    log_event(cfg, {
        "event": "block_bash",
        "session": data.get("session_id") or "",
        "cwd": cwd,
        "file": path,
        "lines": n,
        "file_tokens_est": size // 4,
    })
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        log_error("check_bash.py: %r" % (exc,))
        sys.exit(0)
