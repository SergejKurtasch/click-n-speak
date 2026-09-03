from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

from analyze_swift_soak import parse_runtime_events, summarize  # noqa: E402
from compare_swift_parity_metrics import evaluate  # noqa: E402
from parity_config_bridge import migrate  # noqa: E402
from swift_acceptance import (  # noqa: E402
    GateResult,
    scenario_result,
    validate_data_copy,
    validate_scenario_manifest,
)


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


def test_manifest_is_complete_and_covers_every_required_area() -> None:
    manifest = load_json(REPO_ROOT / "tests/parity/swift_parity_scenarios.json")
    scenarios = validate_scenario_manifest(manifest)
    areas = {str(item["area"]) for item in scenarios}
    assert {
        "permissions",
        "session",
        "popup",
        "injection",
        "stt",
        "editor",
        "runtime",
        "history",
        "menu",
        "dictionary",
        "data",
        "lifecycle",
        "models",
        "autostart",
        "update",
        "distribution",
        "ui",
        "accessibility",
        "privacy",
        "soak",
        "rollback",
    } <= areas
    assert all(item["release_critical"] for item in scenarios)
    assert any(item["classification"] == "automated" for item in scenarios)
    assert any(item["classification"] == "manual" for item in scenarios)
    assert any(item["classification"] == "hybrid" for item in scenarios)


def test_python_migrates_every_supported_schema_without_unknown_key_loss() -> None:
    document = load_json(REPO_ROOT / "tests/parity/fixtures/config_schemas.json")
    fixtures = document["fixtures"]
    assert isinstance(fixtures, list)
    versions = set()
    for fixture in fixtures:
        assert isinstance(fixture, dict)
        config = copy.deepcopy(fixture["config"])
        assert isinstance(config, dict)
        versions.add(int(config.get("schema_version", 1)))
        migrated = migrate(config)
        assert migrated["schema_version"] == 9
        assert migrated["future_extension"]["owner"] == "parity"
    assert versions == set(range(1, 10))


def test_metric_thresholds_are_complete_and_fail_closed() -> None:
    thresholds = load_json(REPO_ROOT / "tests/parity/quality_thresholds.json")
    policies = thresholds["thresholds"]
    assert isinstance(policies, dict)
    passing_metrics = {
        name: policy["value"]
        for name, policy in policies.items()
    }
    results, failures = evaluate({"metrics": passing_metrics}, thresholds)
    assert not failures
    assert all(result["status"] == "passed" for result in results)

    missing_metrics = dict(passing_metrics)
    missing_metrics.pop("overall_wer")
    _, failures = evaluate({"metrics": missing_metrics}, thresholds)
    assert failures == ["overall_wer"]


def test_acceptance_requires_a_copy_not_live_data(tmp_path: Path) -> None:
    assert validate_data_copy(tmp_path, REPO_ROOT) == tmp_path.resolve()
    with pytest.raises(ValueError):
        validate_data_copy(REPO_ROOT, REPO_ROOT)
    production = Path.home() / "Library" / "Application Support" / "Click-n-speak"
    with pytest.raises(ValueError):
        validate_data_copy(production, REPO_ROOT)


def test_hybrid_scenario_requires_both_automatic_and_manual_evidence() -> None:
    scenario = {
        "id": "hybrid.fixture",
        "area": "fixture",
        "classification": "hybrid",
        "release_critical": True,
        "evidence_gate": "swift_fast",
        "evidence_location": "manual.json",
        "intentional_deviation": None,
    }
    gates = {
        "swift_fast": GateResult("swift_fast", "passed", 1.0, "tests")
    }
    assert scenario_result(scenario, gates, {})["status"] == "skipped"
    manual = {"hybrid.fixture": {"status": "passed", "evidence": "manual.json"}}
    assert scenario_result(scenario, gates, manual)["status"] == "passed"


def test_soak_summary_uses_only_privacy_safe_structured_events(tmp_path: Path) -> None:
    log_path = tmp_path / "runtime.log"
    lines = [
        {"event": "session_start", "monotonic": 1.0, "session_id": 1, "hud_latency_ms": 10.0},
        {"event": "popup_presented", "monotonic": 3.0, "session_id": 1, "stop_to_popup_ms": 500.0},
        {"event": "editor_refine", "monotonic": 3.1, "session_id": 1, "duration_ms": 100.0, "status": "ok"},
        {"event": "process_snapshot", "monotonic": 3.2, "session_id": 1, "parent_rss_mb": 100.0},
        {"event": "audio_capture_stats", "monotonic": 3.3, "maximum_callback_ms": 2.0, "overflow_samples": 0},
    ]
    log_path.write_text(
        "\n".join(f"prefix runtime_event {json.dumps(line)}" for line in lines),
        encoding="utf-8",
    )
    result = summarize(parse_runtime_events(log_path))
    assert result["session_count"] == 1
    assert result["hotkey_to_hud_p95_seconds"] == 0.01
    assert result["stop_to_popup_p95_seconds"] == 0.5
    assert result["audio_overflow_count"] == 0

    log_path.write_text(
        'runtime_event {"event":"bad","monotonic":1,"transcript":"private"}\n',
        encoding="utf-8",
    )
    with pytest.raises(ValueError):
        parse_runtime_events(log_path)
