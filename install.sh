#!/bin/bash
# Install the shunt harness into ~/.claude/shunt and wire its two PreToolUse hooks.
# Safe to re-run: an existing config.json and log/ are preserved, and the settings
# merge never duplicates entries.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/shunt"
SETTINGS="$HOME/.claude/settings.json"
BINDIR="$HOME/.local/bin"
STAMP="$(date +%Y-%m-%d-%H%M%S)"

if [ ! -d "$SRC/shunt" ]; then
  echo "install.sh: no shunt/ directory next to this script" >&2
  exit 1
fi

echo "==> installing to $DEST"
mkdir -p "$DEST" "$DEST/log" "$BINDIR" "$HOME/.claude"

KEEP=""
if [ -f "$DEST/config.json" ]; then
  KEEP="$(mktemp -t shunt_cfg)"
  cp "$DEST/config.json" "$KEEP"
  echo "    keeping existing config.json"
fi

# copy the tree; log/ is not part of the source, so it is left untouched
cp -R "$SRC/shunt/." "$DEST/"

if [ -n "$KEEP" ]; then
  # keep the user's values, add any keys this version introduced
  python3 - "$KEEP" "$SRC/shunt/config.json" "$DEST/config.json" <<'PY'
import json, sys
kept = json.load(open(sys.argv[1]))
shipped = json.load(open(sys.argv[2]))
added = [k for k in shipped if k not in kept]
for k in added:
    kept[k] = shipped[k]
with open(sys.argv[3], "w") as fh:
    json.dump(kept, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
if added:
    print("    added new config keys: %s" % ", ".join(added))
PY
  rm -f "$KEEP"
fi

chmod +x "$DEST/bin/shunt" "$DEST/hooks/"*.py "$DEST/scripts/bulk_read.sh" \
  "$DEST/tests/run_tests.sh" 2>/dev/null

echo "==> merging PreToolUse hooks into $SETTINGS"
python3 - "$SETTINGS" "$STAMP" <<'PY'
import json, os, shutil, sys

path, stamp = sys.argv[1], sys.argv[2]
entries = [
    ("Read", 'python3 "$HOME/.claude/shunt/hooks/check_read.py"'),
    ("Bash", 'python3 "$HOME/.claude/shunt/hooks/check_bash.py"'),
]

data = {}
if os.path.exists(path):
    with open(path) as fh:
        raw = fh.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except Exception as exc:
        sys.exit("settings.json is not valid JSON (%r); fix it and re-run" % (exc,))
    backup = "%s.bak-%s-shunt" % (path, stamp)
    shutil.copy2(path, backup)
    print("    backup: %s" % backup)

hooks = data.setdefault("hooks", {})
pre = hooks.setdefault("PreToolUse", [])
if not isinstance(pre, list):
    sys.exit("hooks.PreToolUse is not a list; refusing to edit")

changed = False
for matcher, command in entries:
    script = command.split("/")[-1].rstrip('"')
    found = None
    for entry in pre:
        if not isinstance(entry, dict):
            continue
        cmds = " ".join(
            h.get("command", "") for h in (entry.get("hooks") or []) if isinstance(h, dict)
        )
        if script in cmds:
            found = entry
            break
    want = {"matcher": matcher,
            "hooks": [{"type": "command", "command": command, "timeout": 10}]}
    if found is None:
        pre.append(want)
        changed = True
        print("    added %s hook" % matcher)
    elif found != want:
        found.clear()
        found.update(want)
        changed = True
        print("    updated %s hook" % matcher)
    else:
        print("    %s hook already present" % matcher)

if changed:
    with open(path, "w") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

n_read = sum(1 for e in pre if isinstance(e, dict) and "check_read.py" in json.dumps(e))
n_bash = sum(1 for e in pre if isinstance(e, dict) and "check_bash.py" in json.dumps(e))
print("    PreToolUse shunt entries: read=%d bash=%d" % (n_read, n_bash))
if n_read != 1 or n_bash != 1:
    sys.exit("expected exactly one Read and one Bash shunt entry")
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

echo "==> installing the bulk-reader skill"
SKILL_SRC="$SRC/shunt/skills/bulk-reader/SKILL.md"
SKILL_DEST="$HOME/.claude/skills/bulk-reader/SKILL.md"
if [ -f "$SKILL_SRC" ]; then
  mkdir -p "$(dirname "$SKILL_DEST")"
  # only ever writes this one file; anything else in ~/.claude/skills is left alone
  cp "$SKILL_SRC" "$SKILL_DEST"
  echo "    $SKILL_DEST"
else
  echo "    skipped: no skills/bulk-reader/SKILL.md in the source tree"
fi

echo "==> symlinking $BINDIR/shunt"
ln -sfn "$DEST/bin/shunt" "$BINDIR/shunt"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "    note: $BINDIR is not on PATH; add it to use the 'shunt' command" ;;
esac

echo
"$DEST/bin/shunt" status
