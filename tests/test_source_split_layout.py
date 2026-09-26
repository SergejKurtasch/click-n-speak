"""Workspace ownership and legacy resource-resolution contracts."""

from __future__ import annotations

import importlib
import sys
from pathlib import Path


WORKSPACE_ROOT = Path(__file__).resolve().parents[1]
LEGACY_ROOT = WORKSPACE_ROOT / "legacy-python"

if str(LEGACY_ROOT) not in sys.path:
    sys.path.insert(0, str(LEGACY_ROOT))


def test_legacy_python_layout_is_self_contained() -> None:
    required = (
        "main.py",
        "src",
        "tests",
        "assets",
        "locales",
        "pyproject.toml",
        "requirements.txt",
        "setup.py",
        "config.example.json",
        "scripts/build.sh",
    )

    assert all((LEGACY_ROOT / path).exists() for path in required)


def test_legacy_resource_resolver_uses_its_root_without_sibling_app() -> None:
    utils = importlib.import_module("src.utils")

    assert utils.ROOT == LEGACY_ROOT
    assert utils.get_menu_icon_path() == LEGACY_ROOT / "assets" / "CnS.png"
    assert utils.get_config_path().parent == LEGACY_ROOT
