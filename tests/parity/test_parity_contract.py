from __future__ import annotations

import copy
import hashlib
import json
import plistlib
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from unittest.mock import Mock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SWIFT_ROOT = REPO_ROOT / "swift-app"
SCRIPTS = SWIFT_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(1, str(REPO_ROOT / "scripts"))

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
    assert {regression_id for item in automated for regression_id in item["regression_ids"]} == {
        f"R{number:02d}" for number in range(1, 16)
    }
    expected_targets = {
        "R01": [
            "ClickNSpeak/Tests/ClickNSpeakTests/AppDelegateStartupTests.swift#startupPreservesCorruptConfig",
            "ClickNSpeak/Tests/ClickNSpeakTests/AppDelegateStartupTests.swift#validBackupRestoresSafely",
        ],
        "R02": [
            "Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift#testDrainAndStopWaitsForOwnedMaintenanceThenFlushesDirtyUsage",
            "ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift#dirtyUsageSurvivesCoordinatorRoundTrip",
        ],
        "R03": [
            "Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift#fileJobBlocksHotkey",
            "Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift#injectingBlocksHotkey",
        ],
        "R04": ["Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift#silentAppendPreservesPopup"],
        "R05": [
            "Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift#appendPreservesDatasetSource",
            "Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift#appendAfterUserEditPreservesProvenance",
        ],
        "R06": ["Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift#partialFailureIsVisible"],
        "R07": [
            "Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift#shutdownBlocksNewActivities",
            "Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift#shutdownCannotReopenPopup",
        ],
        "R08": [
            "ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift#preparationCannotCommitIntoRecording"
        ],
        "R09": [
            "ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift#sharedGeminiCredentialRebuildsBothComponents",
            "ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift#revalidationRebuildsActiveClient",
        ],
        "R10": ["ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift#languageChangeRebuildsPrompt"],
        "R11": [
            "Packages/CNSUI/Tests/CNSUITests/UIPanelsTests.swift#testFileTypesMatchPythonPickerAndCredentialValidationIsProviderSpecific"
        ],
        "R12": ["Packages/CNSCore/Tests/CNSCoreTests/ModelDownloaderNetworkTests.swift#get404IsTerminal"],
        "R13": [
            "Packages/CNSCore/Tests/CNSCoreTests/UpdateProcessLifecycleTests.swift#testLiveParentPreventsAnySwapMutation"
        ],
        "R14": ["Packages/CNSInput/Tests/CNSInputTests/SystemTextDeliveryTests.swift#missingTargetPreservesText"],
        "R15": [
            "Packages/CNSCore/Tests/CNSCoreTests/RuntimeTelemetryTests.swift#testTelemetryRejectsContentBearingFieldNames",
            "tests/parity/test_parity_contract.py#test_passed_manual_evidence_is_bound_to_verified_candidate_artifacts",
        ],
    }
    regression_scenarios = {item["regression_ids"][0]: item for item in automated if item["regression_ids"]}
    assert set(regression_scenarios) == set(expected_targets)
    for regression_id, targets in expected_targets.items():
        assert regression_scenarios[regression_id]["id"].startswith(f"regression.{regression_id}.")
        assert regression_scenarios[regression_id]["test_targets"] == targets


def test_original_eleven_audit_probes_are_permanent_selected_tests() -> None:
    scenarios = validate_scenario_manifest(load_json(REPO_ROOT / "tests/parity/swift_parity_scenarios.json"))
    selected = {target for scenario in scenarios for target in scenario.get("test_targets", []) if "#" in target}
    runtime_file = "ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift"
    startup_file = "ClickNSpeak/Tests/ClickNSpeakTests/AppDelegateStartupTests.swift"
    session_file = "Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift"
    expected = {
        f"{runtime_file}#revalidationRebuildsActiveClient",
        f"{runtime_file}#preparationCannotCommitIntoRecording",
        f"{runtime_file}#dirtyUsageSurvivesCoordinatorRoundTrip",
        f"{startup_file}#startupPreservesCorruptConfig",
        f"{runtime_file}#languageChangeRebuildsPrompt",
        f"{session_file}#fileJobBlocksHotkey",
        f"{session_file}#injectingBlocksHotkey",
        f"{session_file}#silentAppendPreservesPopup",
        f"{session_file}#appendPreservesDatasetSource",
        f"{session_file}#partialFailureIsVisible",
        f"{session_file}#shutdownCannotReopenPopup",
    }
    assert expected <= selected
    for target in expected:
        source, test_name = target.split("#", 1)
        source_path = REPO_ROOT / source
        if not source_path.exists():
            source_path = SWIFT_ROOT / source
        assert f"func {test_name}(" in source_path.read_text(encoding="utf-8")


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
    passing_metrics = {name: policy["value"] for name, policy in policies.items()}
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
    gates = {"swift_fast": GateResult("swift_fast", "passed", 1.0, "tests")}
    assert scenario_result(scenario, gates, {})["status"] == "skipped"
    manual = {"hybrid.fixture": {"status": "passed", "evidence": "manual.json"}}
    assert scenario_result(scenario, gates, manual)["status"] == "passed"


def test_passed_manual_evidence_is_bound_to_verified_candidate_artifacts(tmp_path: Path) -> None:
    app = tmp_path / "Click-n-speak.app"
    dmg = tmp_path / "Click-n-speak.dmg"
    evidence_artifact = tmp_path / "manual-result.json"
    app.write_bytes(b"app-candidate")
    dmg.write_bytes(b"dmg-candidate")
    evidence_artifact.write_text('{"status":"passed"}\n', encoding="utf-8")
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
                        "completed_at": (datetime.now(UTC) + timedelta(minutes=1)).isoformat(),
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
    artifact.write_text('{"status":"passed"}\n', encoding="utf-8")
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
                        "completed_at": (datetime.now(UTC) + timedelta(minutes=1)).isoformat(),
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

    assert scenario_result(scenario, {"stt_model": missing}, {})["status"] == "missing_prerequisite"
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


def test_candidate_identity_rejects_non_commit_revision(tmp_path: Path) -> None:
    app = tmp_path / "candidate.app"
    dmg = tmp_path / "candidate.dmg"
    app.write_bytes(b"app")
    dmg.write_bytes(b"dmg")

    with pytest.raises(ValueError, match="revision"):
        build_candidate_identity(
            git_revision="not-a-git-revision",
            version="1.1.0",
            app_path=app,
            dmg_path=dmg,
            model_revisions={"whisper": "abc123"},
            os_version="macOS 15",
            hardware="Apple M4",
        )


def test_candidate_identity_records_exact_model_artifact(tmp_path: Path) -> None:
    app = tmp_path / "candidate.app"
    dmg = tmp_path / "candidate.dmg"
    model = tmp_path / "model"
    app.write_bytes(b"app")
    dmg.write_bytes(b"dmg")
    model.mkdir()
    (model / "weights.bin").write_bytes(b"first")

    candidate = build_candidate_identity(
        git_revision="f6337d7",
        version="1.1.0",
        app_path=app,
        dmg_path=dmg,
        model_revisions={"whisper": "abc123"},
        model_artifacts={"whisper": model},
        os_version="macOS 15",
        hardware="Apple M4",
    )

    assert candidate["model_artifacts"]["whisper"]["sha256"]
    (model / "weights.bin").write_bytes(b"second")
    from swift_acceptance import verify_candidate_artifacts

    with pytest.raises(ValueError, match="model"):
        verify_candidate_artifacts(candidate)


def test_stt_model_gate_accepts_an_explicitly_identified_model_before_corpus_validation(tmp_path: Path) -> None:
    model = tmp_path / "ggml-model.bin"
    model.write_bytes(b"synthetic model path")
    missing_corpus = tmp_path / "missing-corpus"
    completed = subprocess.run(
        ["bash", str(SWIFT_ROOT / "scripts/swift_verify_stt_model.sh")],
        env={
            "PATH": "/usr/bin:/bin",
            "CNS_WHISPER_MODEL": str(model),
            "CNS_WHISPER_MODEL_ID": "fixture-model",
            "CNS_STT_GOLDEN_DIR": str(missing_corpus),
        },
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 2
    assert "CNS_STT_GOLDEN_DIR" in completed.stderr


def test_stt_model_gate_requires_an_explicit_id_for_an_unknown_filename(tmp_path: Path) -> None:
    model = tmp_path / "ggml-model.bin"
    model.write_bytes(b"synthetic model path")
    completed = subprocess.run(
        ["bash", str(SWIFT_ROOT / "scripts/swift_verify_stt_model.sh")],
        env={"PATH": "/usr/bin:/bin", "CNS_WHISPER_MODEL": str(model)},
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 2
    assert "CNS_WHISPER_MODEL_ID is required" in completed.stderr


def test_candidate_dmg_must_contain_the_exact_app(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from swift_acceptance import verify_dmg_application

    app = tmp_path / "candidate.app"
    app.mkdir()
    (app / "executable").write_bytes(b"expected")
    dmg = tmp_path / "candidate.dmg"
    dmg.write_bytes(b"disk image fixture")
    candidate = build_candidate_identity(
        git_revision="f6337d7",
        version="1.1.0",
        app_path=app,
        dmg_path=dmg,
        model_revisions={"whisper": "abc123"},
        os_version="macOS 15",
        hardware="Apple M4",
    )
    mount_path = tmp_path / "mount"
    mount_path.mkdir()
    monkeypatch.setattr("swift_acceptance.tempfile.mkdtemp", lambda **_kwargs: str(mount_path))
    monkeypatch.setattr("swift_acceptance.subprocess.run", Mock(return_value=Mock(returncode=0)))

    with pytest.raises(ValueError, match="does not contain"):
        verify_dmg_application(candidate)


def test_release_manifest_rejects_a_different_source_revision(tmp_path: Path) -> None:
    from swift_acceptance import _validate_release_manifest

    app = tmp_path / "candidate.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.1.0", "CNSGitRevision": "f6337d7"}))
    dmg = tmp_path / "candidate.dmg"
    dmg.write_bytes(b"disk image fixture")
    candidate = build_candidate_identity(
        git_revision="f6337d7",
        version="1.1.0",
        app_path=app,
        dmg_path=dmg,
        model_revisions={"whisper": "abc123"},
        os_version="macOS 15",
        hardware="Apple M4",
    )
    manifest = tmp_path / "release.manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "git_revision": "0e065f1",
                "version": "1.1.0",
                "dmg": {
                    "sha256": candidate["dmg"]["sha256"],
                    "file_name": dmg.name,
                    "size": dmg.stat().st_size,
                },
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="revision"):
        _validate_release_manifest(manifest, candidate)

    corrected = load_json(manifest)
    corrected["git_revision"] = candidate["git_revision"]
    manifest.write_text(json.dumps(corrected), encoding="utf-8")
    _validate_release_manifest(manifest, candidate)

    info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.1.0", "CNSGitRevision": "0e065f1"}))
    with pytest.raises(ValueError, match="bundle git revision"):
        _validate_release_manifest(manifest, candidate)


def test_bundle_hash_frames_paths_and_rejects_external_symlink(tmp_path: Path) -> None:
    from swift_acceptance import sha256_path

    first = tmp_path / "first.app"
    second = tmp_path / "second.app"
    first.mkdir()
    second.mkdir()
    (first / "a").write_bytes(b"xb\0y")
    (second / "a").write_bytes(b"x")
    (second / "b").write_bytes(b"y")

    assert sha256_path(first) != sha256_path(second)

    original_hash = sha256_path(second)
    (second / "a").chmod(0o755)
    assert sha256_path(second) != original_hash

    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "code").write_bytes(b"external")
    (first / "Frameworks").symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError, match="symlink"):
        sha256_path(first)


@pytest.mark.parametrize(
    "completed_at",
    [
        "not-a-date",
        "2026-09-12T10:00:00",
        "2000-01-01T00:00:00Z",
        (datetime.now(UTC) + timedelta(days=1)).isoformat(),
    ],
)
def test_passed_evidence_rejects_invalid_completion_time_and_empty_result(
    tmp_path: Path,
    completed_at: str,
) -> None:
    app = tmp_path / "candidate.app"
    dmg = tmp_path / "candidate.dmg"
    result = tmp_path / "result.json"
    app.write_bytes(b"app")
    dmg.write_bytes(b"dmg")
    result.write_text('{"status":"passed"}\n', encoding="utf-8")
    candidate = build_candidate_identity(
        git_revision="f6337d7",
        version="1.1.0",
        app_path=app,
        dmg_path=dmg,
        model_revisions={"whisper": "abc123"},
        os_version="macOS 15",
        hardware="Apple M4",
    )
    evidence = {
        "schema_version": 2,
        "candidate": candidate,
        "results": {
            "manual.fixture": {
                "status": "passed",
                "operator": "operator",
                "completed_at": completed_at,
                "artifact": {"path": str(result), "sha256": hashlib.sha256(result.read_bytes()).hexdigest()},
            }
        },
    }
    path = tmp_path / "evidence.json"
    path.write_text(json.dumps(evidence), encoding="utf-8")

    with pytest.raises(ValueError):
        load_manual_evidence(path, expected_candidate=candidate)

    result.write_bytes(b"")
    evidence["results"]["manual.fixture"]["completed_at"] = (datetime.now(UTC) + timedelta(minutes=1)).isoformat()
    evidence["results"]["manual.fixture"]["artifact"]["sha256"] = hashlib.sha256(b"").hexdigest()
    path.write_text(json.dumps(evidence), encoding="utf-8")
    with pytest.raises(ValueError, match="non-empty"):
        load_manual_evidence(path, expected_candidate=candidate)


@pytest.mark.parametrize(
    "target",
    [
        "Packages/CNSCore/Tests/DoesNotExist.swift",
        "tests/../../pyproject.toml",
        "swift-app/Packages/CNSCore/Tests/CNSCoreTests/RuntimeTelemetryTests.swift",
    ],
)
def test_scenario_target_rejects_missing_or_escaping_path(target: str) -> None:
    from swift_acceptance import scenario_gate_command

    with pytest.raises(ValueError):
        scenario_gate_command(REPO_ROOT, [target])


def test_swift_scenario_target_uses_exact_suite_filter() -> None:
    from swift_acceptance import scenario_gate_command

    command = scenario_gate_command(
        SWIFT_ROOT,
        ["Packages/CNSCore/Tests/CNSCoreTests/RuntimeTelemetryTests.swift"],
    )

    assert command[-2:] == ["--filter", "RuntimeTelemetryTests"]
    selected = scenario_gate_command(
        SWIFT_ROOT,
        [
            "Packages/CNSCore/Tests/CNSCoreTests/RuntimeTelemetryTests.swift#testTelemetryRejectsContentBearingFieldNames"
        ],
    )
    assert selected[-2:] == ["--filter", "testTelemetryRejectsContentBearingFieldNames"]
    python_selected = scenario_gate_command(
        REPO_ROOT,
        ["tests/parity/test_parity_contract.py#test_passed_manual_evidence_is_bound_to_verified_candidate_artifacts"],
    )
    assert python_selected[-1] == (
        "tests/parity/test_parity_contract.py::test_passed_manual_evidence_is_bound_to_verified_candidate_artifacts"
    )


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
    assert result.evidence_sha256 == hashlib.sha256(log_path.read_bytes()).hexdigest()
    with pytest.raises(FileExistsError):
        run_gate(
            name="bundle_dev",
            command=["scripts/swift_build_app.sh", "release"],
            repo_root=tmp_path,
            environment=environment,
            log_path=log_path,
        )
    assert invocation.call_args.kwargs["env"]["CNS_PRODUCTION_RELEASE"] == "0"
    assert invocation.call_args.kwargs["env"]["CNS_RESET_TCC_AFTER_BUILD"] == "0"
    assert invocation.call_args.kwargs["env"]["ORIGINAL"] == "yes"


def test_scenario_gate_executes_every_declared_test_target(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    invocation = Mock(return_value=Mock(returncode=0, stdout="1 passed\nExecuted 1 test, with 0 failures\n"))
    monkeypatch.setattr("swift_acceptance.subprocess.run", invocation)

    result = run_scenario_gate(
        name="scenario.data.swift_roundtrip",
        test_targets=[
            "Packages/CNSCore/Tests/CNSCoreTests/ParityDataCompatibilityTests.swift",
            "Packages/CNSCore/Tests/CNSCoreTests/RuntimeTelemetryTests.swift",
        ],
        repo_root=SWIFT_ROOT,
        environment={"CNS_RESET_TCC_AFTER_BUILD": "0"},
        log_path=tmp_path / "gates" / "scenario-data.log",
    )

    assert result.status == "passed"
    assert invocation.call_count == 2


def test_scenario_gate_rejects_successful_process_with_zero_selected_tests(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    invocation = Mock(return_value=Mock(returncode=0, stdout="Executed 0 tests, with 0 failures\n"))
    monkeypatch.setattr("swift_acceptance.subprocess.run", invocation)

    result = run_scenario_gate(
        name="scenario.empty",
        test_targets=["Packages/CNSCore/Tests/CNSCoreTests/RuntimeTelemetryTests.swift"],
        repo_root=SWIFT_ROOT,
        environment={},
        log_path=tmp_path / "scenario-empty.log",
    )

    assert result.status == "failed"
    assert result.evidence_sha256 == hashlib.sha256(Path(result.evidence).read_bytes()).hexdigest()


def test_data_copy_audit_requires_real_dataset_and_verified_backup_manifest(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="dataset"):
        audit_data_copy(tmp_path)

    dataset = tmp_path / "clicknspeak_dataset.jsonl"
    dataset.write_text('{"raw_whisper":"safe fixture"}\n', encoding="utf-8")
    config = tmp_path / "config.json"
    corrections = tmp_path / "corrections.json"
    config.write_text("{}\n", encoding="utf-8")
    corrections.write_text("{}\n", encoding="utf-8")
    entries = [
        {"name": item.name, "sha256": hashlib.sha256(item.read_bytes()).hexdigest(), "size": item.stat().st_size}
        for item in (dataset, config, corrections)
    ]
    (tmp_path / "backup_manifest.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "candidate_version": "1.1.0",
                "files": entries,
            }
        ),
        encoding="utf-8",
    )

    passed, detail = audit_data_copy(tmp_path)

    assert passed is True
    assert "clicknspeak_dataset.jsonl" in detail
    assert "backup_manifest.json" in detail

    truncated = dict(load_json(tmp_path / "backup_manifest.json"))
    truncated["files"] = [entry for entry in entries if entry["name"] != "config.json"]
    (tmp_path / "backup_manifest.json").write_text(json.dumps(truncated), encoding="utf-8")
    with pytest.raises(ValueError, match="config.json"):
        audit_data_copy(tmp_path)


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
        "\n".join(f"prefix runtime_event {json.dumps({**line, 'run_id': 'synthetic-run'})}" for line in lines),
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
