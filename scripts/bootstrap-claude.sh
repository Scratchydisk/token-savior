#!/usr/bin/env bash
set -euo pipefail

SERVER_NAME="token-savior-recall"
SCOPE="user"
CLIENT_NAME="claude-code"
INSTALL_EXTRAS="mcp,memory-vector"
DO_WARMUP=1
DO_MCP=1
DO_HOOKS=1

usage() {
  cat <<'USAGE'
Usage:
  scripts/bootstrap-claude.sh --workspace-root /absolute/project/path [--workspace-root /another/project]

Fresh Claude Code setup for Token Savior:
  - creates .venv if missing
  - installs .[mcp,memory-vector]
  - registers the token-savior-recall MCP server
  - installs Claude Code memory hooks
  - warms the local embedding model
  - runs scripts/doctor.sh

Options:
  --workspace-root PATH   Absolute workspace root to register. May be repeated.
  --no-mcp               Skip Claude MCP registration.
  --no-hooks             Skip hook installation.
  --no-warmup            Skip embedding model warmup.
  --extras EXTRAS        pip extras to install. Default: mcp,memory-vector
  -h, --help             Show this help.
USAGE
}

declare -a workspace_roots=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root)
      workspace_roots+=("${2:?missing path after --workspace-root}")
      shift 2
      ;;
    --no-mcp)
      DO_MCP=0
      shift
      ;;
    --no-hooks)
      DO_HOOKS=0
      shift
      ;;
    --no-warmup)
      DO_WARMUP=0
      shift
      ;;
    --extras)
      INSTALL_EXTRAS="${2:?missing value after --extras}"
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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
PYTHON="$REPO_ROOT/.venv/bin/python"
PIP="$PYTHON -m pip"

if [[ "$DO_MCP" = "1" && "${#workspace_roots[@]}" -eq 0 ]]; then
  echo "Error: at least one --workspace-root is required unless --no-mcp is set." >&2
  exit 2
fi

declare -a abs_roots=()
for root in "${workspace_roots[@]}"; do
  if [[ "$root" != /* ]]; then
    echo "Error: workspace root must be absolute: $root" >&2
    exit 1
  fi
  if [[ ! -d "$root" ]]; then
    echo "Error: workspace root is not a directory: $root" >&2
    exit 1
  fi
  abs_roots+=("$(CDPATH= cd -- "$root" && pwd -P)")
done

if [[ ! -x "$PYTHON" ]]; then
  echo "Creating venv at $REPO_ROOT/.venv"
  python3 -m venv "$REPO_ROOT/.venv"
fi

echo "Installing Token Savior extras: [$INSTALL_EXTRAS]"
$PIP install -e ".[$INSTALL_EXTRAS]"

if [[ "$DO_MCP" = "1" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "Error: claude CLI not found on PATH; cannot register MCP server." >&2
    exit 1
  fi
  joined_roots="$(IFS=','; printf '%s' "${abs_roots[*]}")"
  if claude mcp get "$SERVER_NAME" >/dev/null 2>&1; then
    claude mcp remove "$SERVER_NAME" -s "$SCOPE" >/dev/null
  fi
  claude mcp add "$SERVER_NAME" "$REPO_ROOT/.venv/bin/token-savior" \
    -s "$SCOPE" \
    -e "WORKSPACE_ROOTS=$joined_roots" \
    -e "TOKEN_SAVIOR_CLIENT=$CLIENT_NAME" >/dev/null
  echo "Registered MCP server $SERVER_NAME with WORKSPACE_ROOTS=$joined_roots"
fi

if [[ "$DO_HOOKS" = "1" ]]; then
  TOKEN_SAVIOR_PYTHON="$PYTHON" "$SCRIPT_DIR/install-claude-hooks.sh" --repo-root "$REPO_ROOT"
fi

if [[ "$DO_WARMUP" = "1" ]]; then
  echo "Warming embedding model"
  "$PYTHON" - <<'PY'
from token_savior.memory.embeddings import embed

vec = embed("token savior vector warmup")
if not vec:
    raise SystemExit("Embedding warmup failed")
print(f"Embedding warmup OK: {len(vec)} dimensions")
PY
fi

"$SCRIPT_DIR/doctor.sh"

echo
echo "Bootstrap complete. Restart Claude Code so MCP and hook changes are active."
