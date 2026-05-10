#!/usr/bin/env bash
set -u

SERVER_NAME="token-savior-recall"
STATUS=0
DO_WARMUP=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/doctor.sh [--warmup]

Checks Token Savior local setup:
  - venv and package imports
  - vector stack and vector tables
  - Claude MCP registration
  - Claude hook installation
  - memory DB row counts
  - recent hook errors

Options:
  --warmup   Also run one embedding call to prove the model is cached/usable.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --warmup)
      DO_WARMUP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
PYTHON="$REPO_ROOT/.venv/bin/python"
SETTINGS="${HOME}/.claude/settings.json"
MEMORY_DB="${TOKEN_SAVIOR_MEMORY_DB:-${HOME}/.local/share/token-savior/memory.db}"
ERR_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/token-savior/hook-errors.log"

ok() { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; STATUS=1; }

echo "Token Savior doctor"
echo "Repo: $REPO_ROOT"
echo

if [[ -x "$PYTHON" ]]; then
  ok "venv python: $PYTHON"
else
  fail "missing venv python: $PYTHON"
fi

if [[ -x "$PYTHON" ]]; then
  python_checks="$(DO_WARMUP="$DO_WARMUP" "$PYTHON" - <<'PY'
from __future__ import annotations

import os
import sqlite3
from pathlib import Path

from token_savior import db_core

print(f"OK   token_savior import")
print(f"{'OK' if db_core.VECTOR_SEARCH_AVAILABLE else 'FAIL'}   VECTOR_SEARCH_AVAILABLE={db_core.VECTOR_SEARCH_AVAILABLE}")
try:
    import sqlite_vec
    conn = sqlite3.connect(":memory:")
    sqlite_vec.load(conn)
    conn.close()
    print("OK   sqlite-vec loads")
except Exception as exc:
    print(f"FAIL sqlite-vec load failed: {exc}")

try:
    conn = db_core.get_db()
    names = {
        row[0]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE name IN ('obs_vectors','symbol_vectors')"
        )
    }
    for name in ("obs_vectors", "symbol_vectors"):
        print(f"{'OK' if name in names else 'FAIL'}   {name} table")
    for table in ("user_prompts", "observations", "obs_vectors", "tool_captures", "sessions"):
        try:
            count = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            print(f"OK   {table}: {count}")
        except Exception as exc:
            print(f"WARN {table}: {exc}")
    conn.close()
except Exception as exc:
    print(f"FAIL memory DB open/migration failed: {exc}")

if os.environ.get("DO_WARMUP") == "1":
    try:
        from token_savior.memory.embeddings import embed
        vec = embed("token savior doctor warmup")
        if vec:
            print(f"OK   embedding warmup: {len(vec)} dimensions")
        else:
            print("FAIL embedding warmup returned no vector")
    except Exception as exc:
        print(f"FAIL embedding warmup failed: {exc}")
PY
)"
  printf '%s\n' "$python_checks"
  if printf '%s\n' "$python_checks" | grep -q '^FAIL'; then
    STATUS=1
  fi
fi

if command -v claude >/dev/null 2>&1; then
  if server_info="$(claude mcp get "$SERVER_NAME" 2>/dev/null)"; then
    command_path="$(printf '%s\n' "$server_info" | sed -n 's/^  Command: //p' | head -n 1)"
    roots="$(printf '%s\n' "$server_info" | sed -n 's/^    WORKSPACE_ROOTS=//p' | head -n 1)"
    ok "Claude MCP registered: $SERVER_NAME"
    [[ -n "$command_path" ]] && ok "MCP command: $command_path" || warn "MCP command not found in claude output"
    [[ -n "$roots" ]] && ok "WORKSPACE_ROOTS: $roots" || warn "WORKSPACE_ROOTS not found in claude output"
  else
    fail "Claude MCP server not registered: $SERVER_NAME"
  fi
else
  warn "claude CLI not found on PATH"
fi

if [[ -f "$SETTINGS" ]]; then
  hook_hits=0
  for hook in memory-session-start.sh memory-userprompt.sh memory-pretooluse.sh memory-posttooluse.sh memory-precompact.sh memory-session-stop.sh; do
    if grep -q "$REPO_ROOT/hooks/$hook" "$SETTINGS"; then
      hook_hits=$((hook_hits + 1))
    fi
  done
  if [[ "$hook_hits" -eq 6 ]]; then
    ok "Claude hooks installed for this checkout"
  else
    fail "Claude hooks incomplete for this checkout ($hook_hits/6 found in $SETTINGS)"
  fi
else
  fail "Claude settings file missing: $SETTINGS"
fi

if [[ -f "$ERR_LOG" ]]; then
  if tail -50 "$ERR_LOG" | grep -q "JSONDecodeError"; then
    warn "recent hook log still contains JSONDecodeError"
  else
    ok "no JSONDecodeError in recent hook log"
  fi
  recent_errors="$(tail -20 "$ERR_LOG" | grep -Ev 'sqlite-vec not installed|model .* has been updated|_model = TextEmbedding|^Auto-mode: ' || true)"
  if [[ -n "$recent_errors" ]]; then
    warn "recent hook log entries:"
    printf '%s\n' "$recent_errors"
  else
    ok "recent hook log has no actionable errors"
  fi
else
  warn "hook error log not found yet: $ERR_LOG"
fi

echo
if [[ "$STATUS" -eq 0 ]]; then
  ok "doctor completed"
else
  fail "doctor found setup problems"
fi
exit "$STATUS"
