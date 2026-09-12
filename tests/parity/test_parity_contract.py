from __future__ import annotations

import copy
import hashlib
import json
import sys
from pathlib import Path
from typing import Any
from unittest.mock import Mock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

from analyze_swift_soak import parse_runtime_events, summarize  # noqa: E402
from compare_swift_parity_metrics import evaluate  # noqa: E402
from parity_config_bridge import migrate  # noqa: E402
from swift_acceptance import (  # noqa: E402
    GateResult,
    audit_data_copy,
    build_candidate_identity,
    build_gate_environment,
    load_manual_evidence,
    run_gate,
    run_scenario_gate,
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


def test_automated_scenarios_have_dedicated_test_targets_and_regression_coverage() -> None:
    manifest = load_json(REPO_ROOT / "tests/parity/swift_parity_scenarios.json")
    scenarios = validate_scenario_manifest(manifest)
    automated = [item for item in scenarios if item["classification"] == "automated"]

    assert all(item["evidence_gate"] != "swift_fast" for item in automated)
    assert all(item["test_targets"] for item in automated)
    assert {
        regression_id
        for item in automated
        for regression_id in item["regression_ids"]
    } == {f"R{number:02d}" for number in range(1, 16)}


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
        assert migrated["schema_version"] == 10
        assert migrated["future_extension"]["owner"] == "parity"
    assert versions == set(range(1, 11))


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


def test_passed_manual_evidence_is_bound_to_verified_candidate_artifacts(tmp_path: Path) -> None:
    app = tmp_path / "Click-n-speak.app"
    dmg = tmp_path / "Click-n-speak.dmg"
    evidence_artifact = tmp_path / "manual-result.json"
    app.write_bytes(b"app-candidate")
    dmg.write_bytes(b"dmg-candidate")
    evidence_artifact.write_text('{"result":"passed"}\n', encoding="utf-8")
    candidate = build_candidate_identity(
        git_revision="f6337d7",
        version="1.1.0",
        app_path=app,
        dmg_path=dmg,
        model_revisions={"whisper": "abc123", "qwen": "def456"},
        os_version="macOS 15.0",
        hardware="Apple M4",
    )
    manual_path = tmp_path / "manual-evidence.json"
    manual_path.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "candidate": candidate,
                "results": {
                    "manual.fixture": {
                        "status": "passed",
                        "operator": "release-operator",
                        "completed_at": "2026-09-12T10:00:00Z",
                        "artifact": {
                            "path": str(evidence_artifact),
                            "sha256": hashlib.sha256(evidence_artifact.read_bytes()).hexdigest(),
                        },
                    }
                },
            }
        ),
        encoding="utf-8",
    )

    result = load_manual_evidence(manual_path, expected_candidate=candidate)

    assert result["manual.fixture"]["status"] == "passed"


@pytest.mark.parametrize(
    "mutation",
    [
        pytest.param("missing", id="missing-artifact"),
        pytest.param("candidate-hash", id="candidate-hash-mismatch"),
        pytest.param("candidate-version", id="stale-candidate-version"),
        pytest.param("corrupt-candidate-app", id="corrupt-candidate-app-checksum"),
        pytest.param("corrupt-artifact", id="corrupt-evidence-checksum"),
    ],
)
def test_passed_manual_evidence_rejects_unverified_candidate_or_artifact(
    tmp_path: Path,
    mutation: str,
) -> None:
    app = tmp_path / "Click-n-speak.app"
    dmg = tmp_path / "Click-n-speak.dmg"
    artifact = tmp_path / "result.json"
    app.write_bytes(b"app")
    dmg.write_bytes(b"dmg")
    artifact.write_text("verified\n", encoding="utf-8")
    candidate = build_candidate_identity(
        git_revision="f6337d7",
        version="1.1.0",
        app_path=app,
        dmg_path=dmg,
        model_revisions={"whisper": "abc123"},
        os_version="macOS 15.0",
        hardware="Apple M4",
    )
    evidence_candidate = copy.deepcopy(candidate)
    artifact_path = artifact
    artifact_sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
    if mutation == "missing":
        artifact_path = tmp_path / "missing.json"
    elif mutation == "candidate-hash":
        evidence_candidate["app"]["sha256"] = "0" * 64
    elif mutation == "candidate-version":
        evidence_candidate["version"] = "1.0.9"
    elif mutation == "corrupt-candidate-app":
        app.write_bytes(b"app-after-evidence")
    elif mutation == "corrupt-artifact":
        artifact_sha = "0" * 64
    manual_path = tmp_path / "manual-evidence.json"
    manual_path.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "candidate": evidence_candidate,
                "results": {
                    "manual.fixture": {
                        "status": "passed",
                        "operator": "release-operator",
                        "completed_at": "2026-09-12T10:00:00Z",
                        "artifact": {"path": str(artifact_path), "sha256": artifact_sha},
                    }
                },
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError):
        load_manual_evidence(manual_path, expected_candidate=candidate)


def test_skipped_manual_evidence_never_becomes_passed() -> None:
    scenario = {
        "id": "manual.fixture",
        "area": "fixture",
        "classification": "manual",
        "release_critical": True,
        "evidence_gate": None,
        "evidence_location": "manual.json",
        "intentional_deviation": None,
    }

    result = scenario_result(scenario, {}, {"manual.fixture": {"status": "skipped"}})

    assert result["status"] == "skipped"


def test_model_gate_missing_prerequisite_is_distinct_from_failed_and_passed() -> None:
    scenario = {
        "id": "stt.fixture",
        "area": "stt",
        "classification": "automated",
        "release_critical": True,
        "evidence_gate": "stt_model",
        "evidence_location": "golden.json",
        "intentional_deviation": None,
    }
    missing = GateResult("stt_model", "missing_prerequisite", 0.0, "", "model is unavailable")
    failed = GateResult("stt_model", "failed", 1.0, "model.log", "golden suite failed")
    passed = GateResult("stt_model", "passed", 1.0, "model.log")

    assert scenario_result(scenario, {"stt_model": missing}, {})["status"] == "skipped"
    assert scenario_result(scenario, {"stt_model": failed}, {})["status"] == "failed"
    assert scenario_result(scenario, {"stt_model": passed}, {})["status"] == "passed"


def test_automated_result_carries_the_verified_candidate_identity() -> None:
    scenario = {
        "id": "automated.fixture",
        "area": "fixture",
        "classification": "automated",
        "release_critical": True,
        "evidence_gate": "scenario.fixture",
        "evidence_location": "fixture.log",
        "intentional_deviation": None,
    }
    candidate = {"git_revision": "f6337d7", "version": "1.1.0"}

    result = scenario_result(
        scenario,
        {"scenario.fixture": GateResult("scenario.fixture", "passed", 1.0, "fixture.log")},
        {},
        candidate,
    )

    assert result["candidate"] == candidate


def test_acceptance_build_environment_preserves_tcc_and_production_switch() -> None:
    environment = build_gate_environment(production=True, base={"UNCHANGED": "1"})

    assert environment["UNCHANGED"] == "1"
    assert environment["CNS_PRODUCTION_RELEASE"] == "1"
    assert environment["CNS_RESET_TCC_AFTER_BUILD"] == "0"


def test_build_gate_records_a_separate_log_and_receives_preserved_tcc_environment(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    completed = Mock(returncode=0)
    invocation = Mock(return_value=completed)
    monkeypatch.setattr("swift_acceptance.subprocess.run", invocation)
    environment = build_gate_environment(production=False, base={"ORIGINAL": "yes"})
    log_path = tmp_path / "gates" / "bundle_dev.log"

    result = run_gate(
        name="bundle_dev",
        command=["scripts/swift_build_app.sh", "release"],
        repo_root=tmp_path,
        environment=environment,
        log_path=log_path,
    )

    assert result.status == "passed"
    assert result.evidence == str(log_path)
    assert log_path.is_file()
    assert invocation.call_args.kwargs["env"]["CNS_PRODUCTION_RELEASE"] == "0"
    assert invocation.call_args.kwargs["env"]["CNS_RESET_TCC_AFTER_BUILD"] == "0"
    assert invocation.call_args.kwargs["env"]["ORIGINAL"] == "yes"


def test_scenario_gate_executes_every_declared_test_target(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    invocation = Mock(return_value=Mock(returncode=0))
    monkeypatch.setattr("swift_acceptance.subprocess.run", invocation)

    result = run_scenario_gate(
        name="scenario.data.python_swift_roundtrip",
        test_targets=[
            "tests/parity/test_parity_contract.py",
            "Packages/CNSCore/Tests/CNSCoreTests/ParityDataCompatibilityTests.swift",
        ],
        repo_root=tmp_path,
        environment={"CNS_RESET_TCC_AFTER_BUILD": "0"},
        log_path=tmp_path / "gates" / "scenario-data.log",
    )

    assert result.status == "passed"
    assert invocation.call_count == 2


def test_data_copy_audit_requires_real_dataset_and_verified_backup_manifest(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="dataset"):
        audit_data_copy(tmp_path)

    dataset = tmp_path / "clicknspeak_dataset.jsonl"
    dataset.write_text('{"raw_whisper":"safe fixture"}\n', encoding="utf-8")
    digest = hashlib.sha256(dataset.read_bytes()).hexdigest()
    (tmp_path / "backup_manifest.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "candidate_version": "1.1.0",
                "files": [{"name": dataset.name, "sha256": digest, "size": dataset.stat().st_size}],
            }
        ),
        encoding="utf-8",
    )

    passed, detail = audit_data_copy(tmp_path)

    assert passed is True
    assert "clicknspeak_dataset.jsonl" in detail
    assert "backup_manifest.json" in detail


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
        "\n".join(
            f"prefix runtime_event {json.dumps({**line, 'run_id': 'synthetic-run'})}"
            for line in lines
        ),
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
