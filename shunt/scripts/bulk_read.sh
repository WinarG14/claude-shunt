#!/bin/bash
# bulk_read.sh <file1> [<file2> ...] "<question>"
# Sends the files (line-numbered) + the question to a cheap worker model and
# prints line-cited bullets plus a one-line cost/latency footer.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
EMPTY_MCP="$SCRIPT_DIR/empty-mcp.json"
WORKDIR="$ROOT/workdir"
CONFIG="$ROOT/config.json"
EVLOG="${SHUNT_LOG_PATH:-$ROOT/log/shunt.log}"
ERRLOG="$ROOT/log/hook_errors.log"

SYS_PROMPT="You are a precise document analyst. Answer the question ONLY from the provided files. Output structured bullets only; no greetings, no prose, no preamble. Every bullet starts with the file's line reference(s) in the form L<n> or L<a>-<b>, then the fact. Quote exact wording for names, values, dates and commands. If the answer is not explicitly stated in the files, output the single bullet: '- NOT IN FILE: <one line on what is closest and where>'. Never infer an order, structure or list that the text does not state."

if [ "$#" -lt 2 ]; then
  echo "usage: bulk_read.sh <file1> [<file2> ...] \"<question>\"" >&2
  exit 1
fi

mkdir -p "$ROOT/log"

# --- config (worker, timeout, logging); falls back to defaults -----------------
eval "$(python3 - "$CONFIG" <<'PY' 2>/dev/null || true
import json, sys, shlex
try:
    c = json.load(open(sys.argv[1]))
except Exception:
    c = {}
print("CFG_WORKER=%s" % shlex.quote(str(c.get("worker", "haiku"))))
print("CFG_TIMEOUT=%s" % shlex.quote(str(int(c.get("worker_timeout_s", 60)))))
print("CFG_LOG=%s" % shlex.quote("1" if c.get("log_enabled", True) else "0"))
PY
)"
WORKER="${SHUNT_WORKER:-${CFG_WORKER:-haiku}}"
TIMEOUT_S="${SHUNT_TIMEOUT:-${CFG_TIMEOUT:-60}}"
LOG_ENABLED="${CFG_LOG:-1}"

# --- args: last one is the question ------------------------------------------
args=("$@")
n=${#args[@]}
QUESTION="${args[$((n-1))]}"
FILES=("${args[@]:0:$((n-1))}")

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "[shunt] not a file: $f" >&2
    exit 1
  fi
done

PROMPT_FILE="$(mktemp -t shunt_prompt)"
RAW_FILE="$(mktemp -t shunt_raw)"
trap 'rm -f "$PROMPT_FILE" "$RAW_FILE"' EXIT

python3 - "$PROMPT_FILE" "$QUESTION" "${FILES[@]}" <<'PY'
import sys
out_path, question = sys.argv[1], sys.argv[2]
files = sys.argv[3:]
with open(out_path, "w", encoding="utf-8") as out:
    out.write(question + "\n\n")
    for f in files:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        out.write('<file path="%s" lines="%d">\n' % (f, len(lines)))
        for i, line in enumerate(lines, 1):
            out.write("%d: %s\n" % (i, line))
        out.write("</file>\n\n")
PY

FILE_BYTES=0
for f in "${FILES[@]}"; do
  sz=$(wc -c < "$f" | tr -d ' ')
  FILE_BYTES=$((FILE_BYTES + sz))
done

START="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"

case "$WORKER" in
  claudex:*)
    MODEL="${WORKER#claudex:}"
    ( cd "$WORKDIR" && \
      env -u CLAUDE_CONFIG_DIR -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
      perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" \
        "$HOME/.claudex/bin/claudex" --model "$MODEL" --allowedTools "" \
        -p --output-format json --system-prompt "$SYS_PROMPT" \
        < "$PROMPT_FILE" ) > "$RAW_FILE" 2>>"$ERRLOG"
    RC=$?
    ;;
  *)
    ( cd "$WORKDIR" && \
      env -u CLAUDE_CONFIG_DIR -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
      perl -e 'alarm shift; exec @ARGV' "$TIMEOUT_S" \
        claude -p --model "$WORKER" \
        --strict-mcp-config --mcp-config "$EMPTY_MCP" \
        --tools "" --max-turns 1 --output-format json \
        --system-prompt "$SYS_PROMPT" \
        < "$PROMPT_FILE" ) > "$RAW_FILE" 2>>"$ERRLOG"
    RC=$?
    ;;
esac

END="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
WALL="$(perl -e 'printf "%.1f", $ARGV[1]-$ARGV[0]' "$START" "$END")"

if [ "$RC" -ne 0 ]; then
  REASON="rc=$RC"
  if [ "$RC" -eq 142 ] || [ "$RC" -eq 14 ]; then REASON="timeout after ${TIMEOUT_S}s"; fi
  echo "[shunt] worker failed rc=$RC ($REASON). Fall back to targeted Reads (offset/limit ≤ 350) of the sections you need." >&2
  if [ "$LOG_ENABLED" = "1" ]; then
    WORKER="$WORKER" WALL="$WALL" FILES_JOINED="$(printf '%s;' "${FILES[@]}")" \
    python3 - "$EVLOG" fail 0 0 0 0 <<'PY'
import json, os, sys, datetime
rec = {"ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
       "event": "worker_fail", "session": "", "cwd": os.getcwd(),
       "file": os.environ.get("FILES_JOINED", ""), "worker": os.environ["WORKER"],
       "wall_s": float(os.environ["WALL"])}
open(sys.argv[1], "a").write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
  fi
  exit "$RC"
fi

WORKER="$WORKER" WALL="$WALL" EVLOG="$EVLOG" LOG_ENABLED="$LOG_ENABLED" \
FILE_BYTES="$FILE_BYTES" FILES_JOINED="$(printf '%s;' "${FILES[@]}")" \
python3 - "$RAW_FILE" <<'PY'
import datetime, json, os, sys
raw = open(sys.argv[1]).read()
try:
    d = json.loads(raw)
except Exception:
    sys.stdout.write(raw)
    sys.stderr.write("[shunt] worker failed rc=0 (unparseable JSON). Fall back to targeted Reads (offset/limit ≤ 350) of the sections you need.\n")
    sys.exit(1)
result = d.get("result", "") or ""
u = d.get("usage", {}) or {}
tin = sum(int(u.get(k, 0) or 0) for k in
          ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
tout = int(u.get("output_tokens", 0) or 0)
cost = d.get("total_cost_usd", 0) or 0
worker = os.environ["WORKER"]
wall = os.environ["WALL"]
print(result)
print("[shunt] worker=%s in=%d out=%d cost=$%s wall=%ss" % (worker, tin, tout, cost, wall))
if os.environ.get("LOG_ENABLED") == "1":
    rec = {"ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
           "event": "worker_call", "session": "", "cwd": os.getcwd(),
           "file": os.environ.get("FILES_JOINED", ""),
           "file_tokens_est": int(os.environ.get("FILE_BYTES", 0)) // 4,
           "returned_tokens_est": len(result) // 4,
           "worker": worker, "in": tin, "out": tout,
           "cost_usd": cost, "wall_s": float(wall)}
    try:
        open(os.environ["EVLOG"], "a").write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass
PY
