"""Structural contract for the promoted Swift-only repository layout."""

from __future__ import annotations

from pathlib import Path
import subprocess


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def test_repository_uses_promoted_swift_layout_without_legacy_runtime() -> None:
    required = (
        "ClickNSpeak/Package.swift",
        "Packages/CNSCore/Package.swift",
        "assets",
        "locales",
        "scripts/swift_verify.sh",
    )
    assert all((REPOSITORY_ROOT / path).exists() for path in required)
    assert not (REPOSITORY_ROOT / "swift-app").exists()
    tracked_paths = subprocess.run(
        ["git", "ls-files", "legacy-python"],
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    assert not tracked_paths.strip()
