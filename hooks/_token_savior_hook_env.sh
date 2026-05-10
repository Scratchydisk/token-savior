#!/bin/sh
# Shared bootstrap for Token Savior hooks.

_ts_hook_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE:-$0}")" 2>/dev/null && pwd -P)
if [ -z "$TOKEN_SAVIOR_ROOT" ]; then
    TOKEN_SAVIOR_ROOT=$(CDPATH= cd -- "$_ts_hook_dir/.." 2>/dev/null && pwd -P)
fi
export TOKEN_SAVIOR_ROOT
export TOKEN_SAVIOR_SRC="${TOKEN_SAVIOR_SRC:-$TOKEN_SAVIOR_ROOT/src}"

if [ -z "$TOKEN_SAVIOR_PYTHON" ]; then
    if [ -x "$TOKEN_SAVIOR_ROOT/.venv/bin/python" ]; then
        TOKEN_SAVIOR_PYTHON="$TOKEN_SAVIOR_ROOT/.venv/bin/python"
    elif [ -x "$TOKEN_SAVIOR_ROOT/.venv/bin/python3" ]; then
        TOKEN_SAVIOR_PYTHON="$TOKEN_SAVIOR_ROOT/.venv/bin/python3"
    else
        TOKEN_SAVIOR_PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || printf '%s' python3)
    fi
fi
export TOKEN_SAVIOR_PYTHON

case ":${PYTHONPATH:-}:" in
    *":$TOKEN_SAVIOR_SRC:"*) ;;
    *) export PYTHONPATH="$TOKEN_SAVIOR_SRC${PYTHONPATH:+:$PYTHONPATH}" ;;
esac

TOKEN_SAVIOR_STATE_DIR="${TOKEN_SAVIOR_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/token-savior}"
TOKEN_SAVIOR_EXPORT_DIR="${TOKEN_SAVIOR_EXPORT_DIR:-$TOKEN_SAVIOR_STATE_DIR/memory-backup}"
export TOKEN_SAVIOR_STATE_DIR TOKEN_SAVIOR_EXPORT_DIR

ERR_LOG="${TOKEN_SAVIOR_HOOK_ERR_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/token-savior/hook-errors.log}"
export ERR_LOG
mkdir -p "$(dirname "$ERR_LOG")" 2>/dev/null || true
if [ -f "$ERR_LOG" ] && [ "$(stat -c%s "$ERR_LOG" 2>/dev/null || echo 0)" -gt 2000000 ]; then
    tail -c 1000000 "$ERR_LOG" > "$ERR_LOG.tmp" 2>/dev/null && mv "$ERR_LOG.tmp" "$ERR_LOG"
fi
