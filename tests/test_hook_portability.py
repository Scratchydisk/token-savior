from __future__ import annotations

import json
import subprocess
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
