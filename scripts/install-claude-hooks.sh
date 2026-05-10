#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/install-claude-hooks.sh [--print] [--settings PATH] [--repo-root PATH]

Installs Token Savior Claude Code memory hooks into ~/.claude/settings.json.
Use --print to emit the JSON snippet without modifying settings.
USAGE
}

PRINT_ONLY=0
SETTINGS="${HOME}/.claude/settings.json"
REPO_ROOT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --print)
            PRINT_ONLY=1
            shift
            ;;
        --settings)
            SETTINGS="${2:?missing path after --settings}"
            shift 2
            ;;
        --repo-root)
            REPO_ROOT="${2:?missing path after --repo-root}"
            shift 2
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

if [ -z "$REPO_ROOT" ]; then
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
else
    REPO_ROOT=$(CDPATH= cd -- "$REPO_ROOT" && pwd -P)
fi

PYTHON="${TOKEN_SAVIOR_PYTHON:-}"
if [ -z "$PYTHON" ]; then
    if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
        PYTHON="$REPO_ROOT/.venv/bin/python"
    elif [ -x "$REPO_ROOT/.venv/bin/python3" ]; then
        PYTHON="$REPO_ROOT/.venv/bin/python3"
    else
        PYTHON=$(command -v python3)
    fi
fi

export TS_INSTALL_REPO_ROOT="$REPO_ROOT"
export TS_INSTALL_PYTHON="$PYTHON"
export TS_INSTALL_SETTINGS="$SETTINGS"
export TS_INSTALL_PRINT_ONLY="$PRINT_ONLY"

"$PYTHON" - <<'PY'
from __future__ import annotations

import json
import os
import shlex
from pathlib import Path


repo_root = Path(os.environ["TS_INSTALL_REPO_ROOT"])
python = os.environ["TS_INSTALL_PYTHON"]
settings_path = Path(os.environ["TS_INSTALL_SETTINGS"]).expanduser()
print_only = os.environ.get("TS_INSTALL_PRINT_ONLY") == "1"


def q(value: str | Path) -> str:
    return shlex.quote(str(value))


def bash_hook(name: str, *args: str) -> str:
    path = repo_root / "hooks" / name
    return " ".join(["bash", q(path), *map(q, args)])


snippet = {
    "hooks": {
        "SessionStart": [
            {
                "hooks": [
                    {"type": "command", "command": bash_hook("memory-session-start.sh"), "timeout": 3000}
                ]
            }
        ],
        "UserPromptSubmit": [
            {
                "hooks": [
                    {"type": "command", "command": bash_hook("memory-userprompt.sh"), "timeout": 3000}
                ]
            }
        ],
        "PreToolUse": [
            {
                "matcher": "Bash|Read|View|NotebookRead|Edit|Write|MultiEdit|mcp__.*",
                "hooks": [
                    {"type": "command", "command": bash_hook("memory-pretooluse.sh"), "timeout": 3000}
                ],
            }
        ],
        "PostToolUse": [
            {
                "matcher": "Bash|WebFetch|web_fetch|WebSearch|Read|Grep|mcp__.*",
                "hooks": [
                    {"type": "command", "command": bash_hook("memory-posttooluse.sh"), "timeout": 5000},
                    {
                        "type": "command",
                        "command": f"{q(python)} {q(repo_root / 'hooks' / 'tool_capture_hook.py')}",
                        "timeout": 5000,
                    },
                ],
            }
        ],
        "PreCompact": [
            {
                "hooks": [
                    {"type": "command", "command": bash_hook("memory-precompact.sh"), "timeout": 3000}
                ]
            }
        ],
        "Stop": [
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": bash_hook("memory-session-stop.sh", "stop"),
                        "timeout": 5000,
                    }
                ]
            }
        ],
    }
}

if print_only:
    print(json.dumps(snippet, indent=2))
    raise SystemExit(0)

if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Refusing to update invalid JSON at {settings_path}: {exc}")
else:
    settings = {}

settings.setdefault("hooks", {})
settings["hooks"].update(snippet["hooks"])
settings_path.parent.mkdir(parents=True, exist_ok=True)
settings_path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"Installed Token Savior hooks into {settings_path}")
print("Restart Claude Code for hook changes to take effect.")
PY
