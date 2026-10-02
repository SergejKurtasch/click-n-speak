"""Structural contract for the promoted Swift-only repository layout."""

from __future__ import annotations

from pathlib import Path
import subprocess
import importlib.util
import json
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def _load_acceptance_module():
    spec = importlib.util.spec_from_file_location("swift_acceptance", REPOSITORY_ROOT / "scripts/swift_acceptance.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


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


def test_tracked_swift_sources_have_no_legacy_runtime_imports_or_archive_paths() -> None:
    source_roots = ("ClickNSpeak", "Packages", "scripts", "spikes")
    source_files = [
        path
        for root in source_roots
        for path in (REPOSITORY_ROOT / root).rglob("*")
        if path.is_file() and path.suffix in {".py", ".swift", ".sh"}
    ]
    violations: list[str] = []
    for path in source_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if "import src" in text or "from src" in text:
            violations.append(f"legacy import: {path}")
        if "Click-n-speak-python-legacy-archive" in text:
            violations.append(f"archive dependency: {path}")
    assert not violations, "\n".join(violations)


def test_acceptance_manifest_is_swift_behavior_only() -> None:
    acceptance = _load_acceptance_module()
    manifest_path = REPOSITORY_ROOT / "tests/parity/swift_parity_scenarios.json"
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    scenarios = acceptance.validate_scenario_manifest(payload)

    assert payload["reference"] == "swift_behavior"
    assert scenarios
    assert all("behavioral_expectation" in item for item in scenarios)
    assert all("expected_behavior" in item for item in scenarios)
    assert all("python_reference" not in item for item in scenarios)
    assert all(
        "python" not in f"{item['behavioral_expectation']} {item['expected_behavior']}".lower()
        for item in scenarios
    )
    rollback = next(item for item in scenarios if item["id"] == "rollback.python_data_read")
    assert rollback["behavioral_expectation"] == (
        "Swift configuration migration preserves supported user data across a Swift round-trip."
    )
    assert rollback["expected_behavior"] == (
        "Swift migrates supported schema versions and preserves unknown keys when configuration is read, "
        "migrated, and written again."
    )
    ui_regression = next(item for item in scenarios if item["id"] == "regression.R11.ui_backend_formats")
    assert ui_regression["evidence_location"].endswith(
        "#testFileTypesMatchPythonPickerAndCredentialValidationIsProviderSpecific"
    )
