#!/bin/bash
# Unit tests for the shunt PreToolUse hooks. Prints PASS/FAIL per case.
# Fixtures are generated here, so the suite has no machine-specific paths.
# Every case writes to a temp event log (SHUNT_LOG_PATH), never the real one, and
# reads a temp config (SHUNT_CONFIG_PATH), so the installed config.json is never
# edited, mutated or restored.
# Exit 1 if any case fails.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Works in both layouts: installed (hooks/ beside tests/) and repo root (shunt/hooks/).
if [ ! -f "$ROOT/hooks/check_read.py" ] && [ -f "$ROOT/shunt/hooks/check_read.py" ]; then
  ROOT="$ROOT/shunt"
fi
READ_HOOK="$ROOT/hooks/check_read.py"
BASH_HOOK="$ROOT/hooks/check_bash.py"
FIX="$ROOT/tests/fixtures"
EXEMPT_DIR="$FIX/exempt_dir"
TMPFIX="${TMPDIR:-/tmp}/shunt_tests"

# The real config must be byte-identical at the end of the run.
REAL_CONFIG="$ROOT/config.json"
REAL_SUM_BEFORE="$(shasum "$REAL_CONFIG" | awk '{print $1}')"

mkdir -p "$EXEMPT_DIR" "$TMPFIX"
python3 - "$TMPFIX" "$EXEMPT_DIR" "$REAL_CONFIG" <<'PY'
import os, sys, json
tmp, exempt, real_config = sys.argv[1], sys.argv[2], sys.argv[3]
def big(path, n, text="line %d filler content for the shunt hook tests"):
    with open(path, "w") as fh:
        for i in range(1, n + 1):
            fh.write((text % i) + "\n")
big(os.path.join(tmp, "big_doc.md"), 900)      # the "large file" under test
big(os.path.join(tmp, "CLAUDE.md"), 400)       # exempt basename
big(os.path.join(exempt, "big_under_claude.md"), 420)  # exempt path prefix
with open(os.path.join(tmp, "small.md"), "w") as fh:
    fh.write("tiny\nfile\n")
with open(os.path.join(tmp, "big.json"), "w") as fh:
    json.dump({"rows": [{"i": i, "v": "x" * 20} for i in range(500)]}, fh, indent=1)
with open(os.path.join(tmp, "big.bin"), "wb") as fh:
    fh.write(b"\x00\x01\x02" * 100 + b"\n" * 500)

# One temp config for the whole suite: the shipped config plus an exempt prefix
# pointing at the generated fixture directory, so the "exempt path prefix" case
# does not depend on the harness being installed under ~/.claude.
cfg = json.load(open(real_config))
cfg["exempt_path_prefixes"] = list(cfg.get("exempt_path_prefixes") or []) + [
    exempt.rstrip("/") + "/"
]
json.dump(cfg, open(os.path.join(tmp, "config.json"), "w"), indent=2)

# Two variants, so no case ever has to edit and restore the real config.
disabled = dict(cfg); disabled["enabled"] = False
json.dump(disabled, open(os.path.join(tmp, "config_disabled.json"), "w"), indent=2)
nobudget = dict(cfg); nobudget["slice_budget_enabled"] = False
json.dump(nobudget, open(os.path.join(tmp, "config_nobudget.json"), "w"), indent=2)
PY

BIG="$TMPFIX/big_doc.md"
BIG_DIR="$TMPFIX"
SMALL="$TMPFIX/small.md"
BIGCLAUDE="$TMPFIX/CLAUDE.md"
BIGJSON="$TMPFIX/big.json"
BIGBIN="$TMPFIX/big.bin"
UNDERCLAUDE="$EXEMPT_DIR/big_under_claude.md"
BULK="$ROOT/scripts/bulk_read.sh"

# All cases read this config, never $ROOT/config.json.
export SHUNT_CONFIG_PATH="$TMPFIX/config.json"
CFG_DISABLED="$TMPFIX/config_disabled.json"
CFG_NOBUDGET="$TMPFIX/config_nobudget.json"

# All cases log here, never to $ROOT/log/shunt.log.
export SHUNT_LOG_PATH="$TMPFIX/unit_shunt.log"
: > "$SHUNT_LOG_PATH"

PASS=0; FAIL=0

# run_case <name> <hook> <expected_rc> <json> [env assignments...]
run_case() {
  local name="$1"; local hook="$2"; local want="$3"; local json="$4"; shift 4
  local err rc
  err="$(printf '%s' "$json" | env "$@" python3 "$hook" 2>&1 >/dev/null)"
  rc=$?
  local ok=1
  [ "$rc" -eq "$want" ] || ok=0
  if [ "$want" -eq 2 ] && [[ "$err" != *"[shunt]"* ]]; then ok=0; fi
  if [ "$ok" -eq 1 ]; then
    PASS=$((PASS+1)); printf 'PASS  %-46s rc=%s\n' "$name" "$rc"
  else
    FAIL=$((FAIL+1)); printf 'FAIL  %-46s rc=%s (want %s) stderr=%s\n' "$name" "$rc" "$want" "$err"
  fi
}

check() { # check <name> <condition-rc> <detail>
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS+1)); printf 'PASS  %-46s %s\n' "$1" "$3"
  else
    FAIL=$((FAIL+1)); printf 'FAIL  %-46s %s\n' "$1" "$3"
  fi
}

jread() { # file_path [extra json fragment] [session]
  python3 -c 'import json,sys
ti={"file_path":sys.argv[1]}
if len(sys.argv)>2 and sys.argv[2]: ti.update(json.loads(sys.argv[2]))
d={"session_id":sys.argv[3],"cwd":"/tmp","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":ti}
if d["session_id"]=="__none__": del d["session_id"]
print(json.dumps(d))' "$1" "${2:-}" "${3:-unittest}"
}
jbash() { # command [cwd] [session]
  python3 -c 'import json,sys
d={"session_id":sys.argv[3],"cwd":sys.argv[2],"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}
if d["session_id"]=="__none__": del d["session_id"]
print(json.dumps(d))' "$1" "${2:-/tmp}" "${3:-unittest}"
}

echo "=== Read hook ==="
run_case "R01 big file, whole-file read -> BLOCK"        "$READ_HOOK" 2 "$(jread "$BIG")" SHUNT_MODE=
run_case "R02 big file, offset+limit 100 -> allow"       "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":100}' r02)" SHUNT_MODE=
run_case "R03 big file, limit 400 -> BLOCK"              "$READ_HOOK" 2 "$(jread "$BIG" '{"offset":1,"limit":400}')" SHUNT_MODE=
run_case "R04 big file, offset only (no limit) -> BLOCK" "$READ_HOOK" 2 "$(jread "$BIG" '{"offset":200}')" SHUNT_MODE=
run_case "R05 small file -> allow"                       "$READ_HOOK" 0 "$(jread "$SMALL")" SHUNT_MODE=
run_case "R06 big CLAUDE.md (exempt basename) -> allow"  "$READ_HOOK" 0 "$(jread "$BIGCLAUDE")" SHUNT_MODE=
run_case "R07 big file under exempt prefix -> allow"     "$READ_HOOK" 0 "$(jread "$UNDERCLAUDE")" SHUNT_MODE=
run_case "R08 big .json (exempt extension) -> allow"     "$READ_HOOK" 0 "$(jread "$BIGJSON")" SHUNT_MODE=
run_case "R09 missing path -> allow"                     "$READ_HOOK" 0 "$(jread "$TMPFIX/no_such_shunt_file.md")" SHUNT_MODE=
run_case "R10 binary file -> allow"                      "$READ_HOOK" 0 "$(jread "$BIGBIN")" SHUNT_MODE=
run_case "R11 no file_path -> allow"                     "$READ_HOOK" 0 '{"tool_name":"Read","tool_input":{}}' SHUNT_MODE=
run_case "R12 SHUNT_MODE=off, big file -> allow"         "$READ_HOOK" 0 "$(jread "$BIG")" SHUNT_MODE=off

echo "=== Bash hook ==="
run_case "B01 cat big -> BLOCK"                          "$BASH_HOOK" 2 "$(jbash "cat '$BIG'")" SHUNT_MODE=
run_case "B02 cat big | head -20 -> allow (pipe)"        "$BASH_HOOK" 0 "$(jbash "cat '$BIG' | head -20")" SHUNT_MODE=
run_case "B03 head -20 big -> allow"                     "$BASH_HOOK" 0 "$(jbash "head -20 '$BIG'" /tmp b03)" SHUNT_MODE=
run_case "B04 head -n 500 big -> BLOCK"                  "$BASH_HOOK" 2 "$(jbash "head -n 500 '$BIG'")" SHUNT_MODE=
run_case "B05 tail -n 20 big -> allow"                   "$BASH_HOOK" 0 "$(jbash "tail -n 20 '$BIG'" /tmp b05)" SHUNT_MODE=
run_case "B06 sed -n '1,50p' big -> allow"               "$BASH_HOOK" 0 "$(jbash "sed -n '1,50p' '$BIG'" /tmp b06)" SHUNT_MODE=
run_case "B07 sed -n '1,600p' big -> BLOCK"              "$BASH_HOOK" 2 "$(jbash "sed -n '1,600p' '$BIG'")" SHUNT_MODE=
run_case "B08 sed 's/a/b/' big (no -n) -> allow"         "$BASH_HOOK" 0 "$(jbash "sed 's/a/b/' '$BIG'")" SHUNT_MODE=
run_case "B09 grep x big -> allow"                       "$BASH_HOOK" 0 "$(jbash "grep -n filler '$BIG'")" SHUNT_MODE=
run_case "B10 cat big > out (redirect) -> allow"         "$BASH_HOOK" 0 "$(jbash "cat '$BIG' > $TMPFIX/out.txt")" SHUNT_MODE=
run_case "B11 heredoc -> allow"                          "$BASH_HOOK" 0 "$(jbash "python3 - <<'EOF'
print(1)
EOF")" SHUNT_MODE=
run_case "B12 relative path with cwd -> BLOCK"           "$BASH_HOOK" 2 "$(jbash "cat big_doc.md" "$BIG_DIR")" SHUNT_MODE=
run_case "B13 cat big CLAUDE.md (exempt) -> allow"       "$BASH_HOOK" 0 "$(jbash "cat '$BIGCLAUDE'")" SHUNT_MODE=
run_case "B14 cat small -> allow"                        "$BASH_HOOK" 0 "$(jbash "cat '$SMALL'")" SHUNT_MODE=
run_case "B15 less big -> BLOCK"                         "$BASH_HOOK" 2 "$(jbash "less '$BIG'")" SHUNT_MODE=
run_case "B16 SHUNT_MODE=off, cat big -> allow"          "$BASH_HOOK" 0 "$(jbash "cat '$BIG'")" SHUNT_MODE=off

echo "=== slice budget ==="
T_LOG="$TMPFIX/budget.log"
: > "$T_LOG"
run_case "T01a slice 1/350 -> allow"                     "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' t01)"   SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T01b slice 351/350 same file -> BLOCK"         "$READ_HOOK" 2 "$(jread "$BIG" '{"offset":351,"limit":350}' t01)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"

: > "$T_LOG"
python3 - "$T_LOG" "$BIG" <<'PY'
import json, os, sys, datetime
rec = {"ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
       "event": "worker_sanctioned", "session": "t02", "cwd": "/tmp",
       "files": [os.path.realpath(sys.argv[2])]}
open(sys.argv[1], "a").write(json.dumps(rec) + "\n")
PY
run_case "T02a sanctioned, slice 1/350 -> allow"         "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' t02)"   SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T02b sanctioned, slice 351/350 -> allow"       "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":351,"limit":350}' t02)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T02c sanctioned, slice 701/350 -> allow"       "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":701,"limit":350}' t02)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"

: > "$T_LOG"
run_case "T03a session A slice 350 -> allow"             "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' t03A)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T03b session B slice 350 -> allow"             "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' t03B)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T03c session B second slice -> BLOCK"          "$READ_HOOK" 2 "$(jread "$BIG" '{"offset":351,"limit":350}' t03B)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T03d session C first slice -> allow"           "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":351,"limit":350}' t03C)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"

: > "$T_LOG"
run_case "T04a budget disabled, slice 350 -> allow"      "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' t04)"   SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG" "SHUNT_CONFIG_PATH=$CFG_NOBUDGET"
run_case "T04b budget disabled, slice 351 -> allow"      "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":351,"limit":350}' t04)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG" "SHUNT_CONFIG_PATH=$CFG_NOBUDGET"
run_case "T04c budget disabled, slice 701 -> allow"      "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":701,"limit":350}' t04)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG" "SHUNT_CONFIG_PATH=$CFG_NOBUDGET"

: > "$T_LOG"
run_case "T05a bulk_read.sh call -> allow"               "$BASH_HOOK" 0 "$(jbash "bash $BULK \"$BIG\" \"what is here\"" /tmp t05)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
grep -q '"event": "worker_sanctioned"' "$T_LOG" && grep -q "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BIG")" "$T_LOG"
check "T05b worker_sanctioned logged with file" $? "$(tr -d '\n' < "$T_LOG" | cut -c1-160)"
run_case "T05c after sanction, 3 x 350 slices -> allow"  "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' t05)"   SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T05d after sanction, slice 351 -> allow"       "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":351,"limit":350}' t05)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T05e after sanction, slice 701 -> allow"       "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":701,"limit":350}' t05)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"

: > "$T_LOG"
run_case "T06a no session_id, slice 350 -> allow"        "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' __none__)"   SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T06b no session_id, slice 351 -> allow"        "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":351,"limit":350}' __none__)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T06c no session_id, slice 701 -> allow"        "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":701,"limit":350}' __none__)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"

: > "$T_LOG"
run_case "T07a head -n 300 big -> allow"                 "$BASH_HOOK" 0 "$(jbash "head -n 300 '$BIG'" /tmp t07)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T07b head -n 300 big again -> BLOCK"           "$BASH_HOOK" 2 "$(jbash "head -n 300 '$BIG'" /tmp t07)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"

: > "$T_LOG"
run_case "T08a Read 350 then bash sed 100 -> allow"      "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' t08)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T08b bash sed -n '351,450p' over budget -> BLOCK" "$BASH_HOOK" 2 "$(jbash "sed -n '351,450p' '$BIG'" /tmp t08)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"

: > "$T_LOG"
run_case "T09a cat of bulk_read.sh -> allow"             "$BASH_HOOK" 0 "$(jbash "cat '$BULK'" /tmp t09)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
! grep -q "worker_sanctioned" "$T_LOG"
check "T09b mentioning the script does not sanction" $? "log lines=$(wc -l < "$T_LOG" | tr -d ' ')"
run_case "T09c t09 slice 1/350 -> allow"                 "$READ_HOOK" 0 "$(jread "$BIG" '{"offset":1,"limit":350}' t09)"   SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"
run_case "T09d t09 slice 351/350 -> BLOCK"               "$READ_HOOK" 2 "$(jread "$BIG" '{"offset":351,"limit":350}' t09)" SHUNT_MODE= "SHUNT_LOG_PATH=$T_LOG"

echo "=== config switch ==="
run_case "C01 config enabled=false, big read -> allow"   "$READ_HOOK" 0 "$(jread "$BIG")" SHUNT_MODE= "SHUNT_CONFIG_PATH=$CFG_DISABLED"
run_case "C02 config enabled=false, cat big -> allow"    "$BASH_HOOK" 0 "$(jbash "cat '$BIG'")" SHUNT_MODE= "SHUNT_CONFIG_PATH=$CFG_DISABLED"
run_case "C03 SHUNT_MODE=on beats enabled=false -> BLOCK" "$READ_HOOK" 2 "$(jread "$BIG")" SHUNT_MODE=on "SHUNT_CONFIG_PATH=$CFG_DISABLED"

echo "=== payload cap, shunt home, config bootstrap ==="
CFG_TINY="$TMPFIX/config_tinypayload.json"
python3 - "$SHUNT_CONFIG_PATH" "$CFG_TINY" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["max_payload_bytes"] = 10
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY

P_LOG="$TMPFIX/payload.log"
: > "$P_LOG"
P_OUT="$(SHUNT_CONFIG_PATH="$CFG_TINY" SHUNT_LOG_PATH="$P_LOG" bash "$BULK" "$BIG" "what is here" 2>&1 >/dev/null)"
P_RC=$?
[ "$P_RC" -eq 1 ] && [[ "$P_OUT" == *"exceeds max_payload_bytes (10)"* ]]
check "P01 payload over cap -> exit 1 with message" $? "rc=$P_RC out=${P_OUT:0:96}"
! grep -q '"event": "worker_call"' "$P_LOG"
check "P02 payload over cap -> no model call" $? "log lines=$(wc -l < "$P_LOG" | tr -d ' ')"
grep -q '"event": "worker_fail"' "$P_LOG" && grep -q 'max_payload_bytes' "$P_LOG"
check "P03 payload over cap -> worker_fail with reason" $? "$(tr -d '\n' < "$P_LOG" | cut -c1-140)"

NEWHOME="$TMPFIX/newhome"
rm -rf "$NEWHOME"
run_case "H01 missing config bootstraps defaults -> BLOCK" "$READ_HOOK" 2 "$(jread "$BIG" '' h01)" SHUNT_MODE= "SHUNT_CONFIG_PATH=" "SHUNT_HOME=$NEWHOME" "SHUNT_LOG_PATH=$TMPFIX/newhome.log"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c.get("enabled") is True else 1)' "$NEWHOME/config.json"
check "H02 default config written, enabled=true" $? "$NEWHOME/config.json"

HOME2="$TMPFIX/home2"
mkdir -p "$HOME2"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["enabled"]=False; json.dump(c, open(sys.argv[2],"w"), indent=2)' "$SHUNT_CONFIG_PATH" "$HOME2/config.json"
run_case "H03 SHUNT_HOME config honoured by read hook"  "$READ_HOOK" 0 "$(jread "$BIG" '' h03)" SHUNT_MODE= "SHUNT_CONFIG_PATH=" "SHUNT_HOME=$HOME2"
run_case "H04 SHUNT_HOME config honoured by bash hook"  "$BASH_HOOK" 0 "$(jbash "cat '$BIG'" /tmp h04)" SHUNT_MODE= "SHUNT_CONFIG_PATH=" "SHUNT_HOME=$HOME2"

SHUNT_BIN="$ROOT/bin/shunt"
env SHUNT_CONFIG_PATH= SHUNT_HOME="$HOME2" SHUNT_MODE= python3 "$SHUNT_BIN" status | grep -q "shunt home *: $HOME2"
check "H05 bin/shunt status reports SHUNT_HOME" $? "$HOME2"
env SHUNT_CONFIG_PATH= SHUNT_HOME="$HOME2" SHUNT_MODE= python3 "$SHUNT_BIN" on >/dev/null \
  && python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c.get("enabled") is True else 1)' "$HOME2/config.json"
check "H06 bin/shunt writes the SHUNT_HOME config" $? "$HOME2/config.json"
env SHUNT_CONFIG_PATH= SHUNT_HOME="$HOME2" python3 "$SHUNT_BIN" version | grep -q "^shunt 0.2.0$"
check "H07 bin/shunt version is 0.2.0" $? "shunt version"

REAL_SUM_AFTER="$(shasum "$REAL_CONFIG" | awk '{print $1}')"
[ "$REAL_SUM_BEFORE" = "$REAL_SUM_AFTER" ] \
  && python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$REAL_CONFIG"
check "C04 real config.json untouched and valid" $? "$REAL_CONFIG"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
