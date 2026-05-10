from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOKS = ROOT / "hooks"


def test_memory_hooks_do_not_embed_author_root_paths() -> None:
    offenders: list[str] = []
    for path in HOOKS.glob("memory-*.sh"):
        text = path.read_text()
        if "/root/token-savior" in text or "/root/.local/token-savior-venv" in text:
            offenders.append(path.name)
    assert offenders == []


def test_memory_hooks_source_shared_environment() -> None:
    for path in HOOKS.glob("memory-*.sh"):
        assert "_token_savior_hook_env.sh" in path.read_text()


def test_hook_config_installer_prints_current_checkout_paths() -> None:
    proc = subprocess.run(
        [
            str(ROOT / "scripts" / "install-claude-hooks.sh"),
            "--print",
            "--repo-root",
            str(ROOT),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    data = json.loads(proc.stdout)
    serialized = json.dumps(data)

    assert str(ROOT / "hooks" / "memory-session-start.sh") in serialized
    assert str(ROOT / "hooks" / "memory-userprompt.sh") in serialized
    assert str(ROOT / "hooks" / "memory-pretooluse.sh") in serialized
    assert str(ROOT / "hooks" / "memory-posttooluse.sh") in serialized
    assert str(ROOT / "hooks" / "memory-precompact.sh") in serialized
    assert str(ROOT / "hooks" / "memory-session-stop.sh") in serialized
    assert "/root/token-savior" not in serialized
    assert "/root/.local/token-savior-venv" not in serialized


def test_memory_userprompt_bootstraps_project_without_existing_observations() -> None:
    text = (HOOKS / "memory-userprompt.sh").read_text()

    assert "CLAUDE_PROJECT_ROOT" in text
    assert "payload.get('cwd')" in text
    assert "os.getcwd()" in text
    assert "project_root=project" in text
    assert "memory_db.prompt_save(None, project, text)" in text


def test_memory_hooks_do_not_embed_payload_in_python_source() -> None:
    for name in ("memory-userprompt.sh", "memory-pretooluse.sh"):
        text = (HOOKS / name).read_text()
        assert "json.loads('''$PAYLOAD''')" not in text
        assert 'json.loads("""$PAYLOAD""")' not in text


def test_userprompt_hook_accepts_quotes_in_payload(tmp_path: Path) -> None:
    db_path = tmp_path / "memory.db"
    state_home = tmp_path / "state"
    payload = {
        "prompt": "what's wrong with this \"menu\" and image [Image #1]?",
        "cwd": str(tmp_path / "workspace"),
    }
    env = {
        **os.environ,
        "TOKEN_SAVIOR_PYTHON": sys.executable,
        "TOKEN_SAVIOR_MEMORY_DB": str(db_path),
        "TOKEN_SAVIOR_STATE_DIR": str(tmp_path / "data"),
        "XDG_STATE_HOME": str(state_home),
    }

    proc = subprocess.run(
        [str(HOOKS / "memory-userprompt.sh")],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=10,
    )

    assert proc.returncode == 0
    err_log = state_home / "token-savior" / "hook-errors.log"
    deadline = time.time() + 2
    while time.time() < deadline:
        if db_path.exists():
            with sqlite3.connect(db_path) as conn:
                row = conn.execute(
                    "SELECT project_root, prompt_text FROM user_prompts ORDER BY id DESC LIMIT 1"
                ).fetchone()
            if row:
                assert row == (payload["cwd"], payload["prompt"])
                break
        time.sleep(0.05)
    else:
        raise AssertionError("user prompt was not archived")
    if err_log.exists():
        assert "JSONDecodeError" not in err_log.read_text()
