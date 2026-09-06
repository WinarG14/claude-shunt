#!/bin/bash
# Remove the shunt PreToolUse hooks from ~/.claude/settings.json.
# --purge also deletes ~/.claude/shunt and the ~/.local/bin/shunt symlink.
set -uo pipefail

SETTINGS="$HOME/.claude/settings.json"
DEST="$HOME/.claude/shunt"
BINLINK="$HOME/.local/bin/shunt"
STAMP="$(date +%Y-%m-%d-%H%M%S)"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> removing PreToolUse hooks from $SETTINGS"
python3 - "$SETTINGS" "$STAMP" <<'PY'
import json, os, shutil, sys

path, stamp = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print("    no settings.json; nothing to do")
    raise SystemExit(0)
with open(path) as fh:
    raw = fh.read()
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception as exc:
    sys.exit("settings.json is not valid JSON (%r); fix it and re-run" % (exc,))

backup = "%s.bak-%s-shunt-uninstall" % (path, stamp)
shutil.copy2(path, backup)
print("    backup: %s" % backup)

pre = (data.get("hooks") or {}).get("PreToolUse")
if not isinstance(pre, list):
    print("    no PreToolUse hooks; nothing to do")
    raise SystemExit(0)

keep = []
removed = 0
for entry in pre:
    blob = json.dumps(entry)
    if "shunt/hooks/check_read.py" in blob or "shunt/hooks/check_bash.py" in blob:
        removed += 1
        continue
    keep.append(entry)
data["hooks"]["PreToolUse"] = keep
if not keep:
    del data["hooks"]["PreToolUse"]
if not data.get("hooks"):
    data.pop("hooks", None)
with open(path, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
print("    removed %d entr%s" % (removed, "y" if removed == 1 else "ies"))
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

if [ "$PURGE" -eq 1 ]; then
  echo "==> purging $DEST and $BINLINK"
  rm -f "$BINLINK"
  rm -rf "$DEST"
else
  echo "    left $DEST in place (use --purge to delete it)"
fi
echo "done"
