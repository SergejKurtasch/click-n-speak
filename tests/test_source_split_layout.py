"""Workspace ownership and legacy resource-resolution contracts."""

from __future__ import annotations

import importlib
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path


WORKSPACE_ROOT = Path(__file__).resolve().parents[1]
LEGACY_ROOT = WORKSPACE_ROOT / "legacy-python"
SWIFT_ROOT = WORKSPACE_ROOT / "swift-app"

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


def test_root_workspace_guides_and_transitional_parity_bridge_remain_available() -> None:
    assert (WORKSPACE_ROOT / "src/AGENTS.md").is_file()
    assert (WORKSPACE_ROOT / "tests/AGENTS.md").is_file()
    assert (WORKSPACE_ROOT / "scripts/parity_config_bridge.py").is_file()


def test_swift_application_layout_is_self_contained() -> None:
    required = (
        "ClickNSpeak/Package.swift",
        "Packages/CNSCore/Package.swift",
        "assets",
        "locales",
        "scripts/swift_verify.sh",
        "scripts/verify_layout.sh",
    )
    assert all((SWIFT_ROOT / path).exists() for path in required)

    native_paths = tuple(SWIFT_ROOT / path for path in ("ClickNSpeak", "Packages"))
    native_text = "\n".join(
        file.read_text(encoding="utf-8")
        for base in native_paths
        for file in base.rglob("*")
        if file.is_file() and file.suffix in {".swift", ".sh", ".py"}
    )
    assert "../legacy-python" not in native_text
    assert "venv/bin/python" not in native_text
    layout_script = (SWIFT_ROOT / "scripts/verify_layout.sh").read_text(encoding="utf-8")
    assert 'for forbidden in' in layout_script
    assert 'rg -n' in layout_script


def test_legacy_launcher_has_standalone_source_and_config_fallback() -> None:
    launcher_script = (LEGACY_ROOT / "scripts/build_launcher.sh").read_text(encoding="utf-8")
    launcher_source = LEGACY_ROOT / "scripts/launcher.c"
    assert launcher_source.is_file()
    assert "launcher.c" in launcher_script
    assert "config.example.json" in launcher_script
    assert "config.json" in launcher_script
    assert '"${RESOURCES}/config.json"' in launcher_script


def test_standalone_launcher_selects_python311_fallback(tmp_path: Path) -> None:
    compiler = shutil.which("cc")
    if compiler is None:
        return
    bundle = tmp_path / "Click-n-speak.app"
    macos = bundle / "Contents" / "MacOS"
    resources = bundle / "Contents" / "Resources"
    python_bin = resources / "python" / "bin"
    app = resources / "app"
    macos.mkdir(parents=True)
    python_bin.mkdir(parents=True)
    app.mkdir(parents=True)
    (app / "main.py").write_text("", encoding="utf-8")
    recorder = tmp_path / "launcher-args.txt"
    python_stub = python_bin / "python3.11"
    python_stub.write_text(
        "#!/bin/sh\nprintf '%s\\n' \"$0|$1|$RESOURCEPATH\" > \"$CNS_LAUNCHER_RECORD\"\n",
        encoding="utf-8",
    )
    python_stub.chmod(python_stub.stat().st_mode | stat.S_IXUSR)
    launcher = macos / "Click-n-speak"
    subprocess.run(
        [compiler, "-O2", "-o", str(launcher), str(LEGACY_ROOT / "scripts/launcher.c")],
        check=True,
        capture_output=True,
        text=True,
    )
    environment = os.environ | {"CNS_LAUNCHER_RECORD": str(recorder)}
    subprocess.run([str(launcher), "--probe"], check=True, env=environment)
    recorded = recorder.read_text(encoding="utf-8").strip().split("|")
    assert recorded[0].endswith("python3.11")
    assert recorded[1].endswith("Resources/app/main.py")
    assert Path(recorded[2]).resolve() == resources.resolve()


def test_swift_locales_do_not_reference_legacy_python_scripts() -> None:
    for locale in (SWIFT_ROOT / "locales").glob("*.json"):
        text = locale.read_text(encoding="utf-8")
        assert "python scripts/download_" not in text
