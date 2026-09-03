"""Non-destructive acceptance orchestration for the Swift cutover candidate."""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

LOGGER = logging.getLogger("swift_acceptance")
VALID_STATUSES = {"passed", "failed", "skipped"}
VALID_CLASSIFICATIONS = {"automated", "manual", "hybrid"}


@dataclass(frozen=True)
class GateResult:
    name: str
    status: str
    duration_seconds: float
    evidence: str
    detail: str | None = None


def load_json_object(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return value


def validate_scenario_manifest(payload: Mapping[str, Any]) -> list[dict[str, Any]]:
    if payload.get("schema_version") != 1:
        raise ValueError("Unsupported parity scenario manifest schema")
    scenarios = payload.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        raise ValueError("Parity scenario manifest must contain scenarios")

    required_keys = {
        "id",
        "area",
        "python_reference",
        "swift_expected",
        "required",
        "fixture_ids",
        "classification",
        "release_critical",
        "evidence_gate",
        "evidence_location",
        "intentional_deviation",
    }
    seen: set[str] = set()
    validated: list[dict[str, Any]] = []
    for raw in scenarios:
        if not isinstance(raw, dict):
            raise ValueError("Every parity scenario must be an object")
        missing = required_keys - raw.keys()
        if missing:
            raise ValueError(f"Scenario is missing keys: {sorted(missing)}")
        scenario_id = raw["id"]
        if not isinstance(scenario_id, str) or not scenario_id:
            raise ValueError("Scenario ID must be a non-empty string")
        if scenario_id in seen:
            raise ValueError(f"Duplicate scenario ID: {scenario_id}")
        seen.add(scenario_id)
        if raw["classification"] not in VALID_CLASSIFICATIONS:
            raise ValueError(f"Invalid classification for {scenario_id}")
        if not isinstance(raw["release_critical"], bool):
            raise ValueError(f"release_critical must be Boolean for {scenario_id}")
        if not isinstance(raw["fixture_ids"], list):
            raise ValueError(f"fixture_ids must be a list for {scenario_id}")
        required = raw["required"]
        if not isinstance(required, dict) or set(required) != {
            "signed_app",
            "permissions",
            "models",
            "network",
        }:
            raise ValueError(f"Invalid requirements object for {scenario_id}")
        validated.append(raw)
    return validated


def load_manual_evidence(path: Path | None) -> dict[str, dict[str, Any]]:
    if path is None:
        return {}
    payload = load_json_object(path)
    if payload.get("schema_version") != 1:
        raise ValueError("Unsupported manual evidence schema")
    raw_results = payload.get("results")
    if not isinstance(raw_results, dict):
        raise ValueError("Manual evidence must contain a results object")
    results: dict[str, dict[str, Any]] = {}
    for scenario_id, result in raw_results.items():
        if not isinstance(result, dict) or result.get("status") not in VALID_STATUSES:
            raise ValueError(f"Invalid manual evidence for {scenario_id}")
        evidence = result.get("evidence")
        if result["status"] == "passed" and (not isinstance(evidence, str) or not evidence):
            raise ValueError(f"Passed manual evidence needs a location: {scenario_id}")
        results[str(scenario_id)] = result
    return results


def validate_data_copy(path: Path, repo_root: Path) -> Path:
    resolved = path.expanduser().resolve()
    production = (
        Path.home() / "Library" / "Application Support" / "Click-n-speak"
    ).resolve()
    if resolved in {production, repo_root.resolve()}:
        raise ValueError("Acceptance requires an explicit copy, never live production or the repository root")
    if not resolved.is_dir():
        raise ValueError(f"Data copy is not a directory: {resolved}")
    return resolved


def audit_data_copy(path: Path) -> tuple[bool, str]:
    """Read only known persistence files and reject malformed structured data."""
    checked: list[str] = []
    config = path / "config.json"
    if config.exists():
        load_json_object(config)
        checked.append("config.json")
    corrections = path / "corrections.json"
    if corrections.exists():
        load_json_object(corrections)
        checked.append("corrections.json")
    for name in ("metrics_history.jsonl", "dataset.jsonl"):
        candidate = path / name
        if not candidate.exists():
            continue
        with candidate.open("r", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                if line.strip():
                    value = json.loads(line)
                    if not isinstance(value, dict):
                        raise ValueError(f"{name}:{line_number} is not a JSON object")
        checked.append(name)
    return True, ", ".join(checked) if checked else "no known structured files present"


def run_gate(
    *,
    name: str,
    command: Sequence[str],
    repo_root: Path,
    environment: Mapping[str, str],
) -> GateResult:
    started = time.monotonic()
    LOGGER.info("Running gate %s", name)
    completed = subprocess.run(
        list(command),
        cwd=repo_root,
        env=dict(environment),
        check=False,
    )
    duration = time.monotonic() - started
    if completed.returncode == 0:
        return GateResult(name, "passed", duration, name)
    return GateResult(
        name,
        "failed",
        duration,
        name,
        f"command exited with status {completed.returncode}",
    )


def scenario_result(
    scenario: Mapping[str, Any],
    gates: Mapping[str, GateResult],
    manual: Mapping[str, Mapping[str, Any]],
) -> dict[str, Any]:
    scenario_id = str(scenario["id"])
    classification = str(scenario["classification"])
    gate_name = scenario.get("evidence_gate")
    gate = gates.get(str(gate_name)) if gate_name else None
    manual_result = manual.get(scenario_id)

    if classification == "automated":
        status = gate.status if gate else "skipped"
        evidence = gate.evidence if gate else str(scenario["evidence_location"])
        detail = gate.detail if gate else "automated gate was not selected"
    elif classification == "manual":
        status = str(manual_result.get("status")) if manual_result else "skipped"
        evidence = (
            str(manual_result.get("evidence"))
            if manual_result
            else str(scenario["evidence_location"])
        )
        detail = None if manual_result else "manual/system evidence was not supplied"
    else:
        if gate and gate.status == "failed":
            status = "failed"
            evidence = gate.evidence
            detail = gate.detail
        elif gate and gate.status == "passed" and manual_result:
            status = str(manual_result.get("status"))
            evidence = str(manual_result.get("evidence", scenario["evidence_location"]))
            detail = None
        else:
            status = "skipped"
            evidence = str(scenario["evidence_location"])
            detail = "hybrid scenario still needs automated or manual evidence"

    return {
        "id": scenario_id,
        "area": scenario["area"],
        "classification": classification,
        "release_critical": scenario["release_critical"],
        "status": status,
        "evidence": evidence,
        "detail": detail,
        "intentional_deviation": scenario["intentional_deviation"],
    }


def write_summary(path: Path, summary: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("tests/parity/swift_parity_scenarios.json"),
    )
    parser.add_argument("--manual-evidence", type=Path)
    parser.add_argument("--data-copy", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("dist/acceptance/swift-acceptance.json"),
    )
    parser.add_argument(
        "--automated-only",
        action="store_true",
        help="Run developer automation but report (rather than fail on) missing manual evidence.",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate manifest/evidence schemas without running build commands.",
    )
    parser.add_argument(
        "--production",
        action="store_true",
        help="Require production signing inputs for the bundle gate.",
    )
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    manifest_path = args.manifest if args.manifest.is_absolute() else repo_root / args.manifest
    output_path = args.output if args.output.is_absolute() else repo_root / args.output
    evidence_path = args.manual_evidence
    if evidence_path is not None and not evidence_path.is_absolute():
        evidence_path = repo_root / evidence_path

    try:
        scenarios = validate_scenario_manifest(load_json_object(manifest_path))
        manual = load_manual_evidence(evidence_path)
        unknown_manual = set(manual) - {str(item["id"]) for item in scenarios}
        if unknown_manual:
            raise ValueError(f"Manual evidence has unknown scenario IDs: {sorted(unknown_manual)}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        LOGGER.error("Acceptance input validation failed: %s", error)
        return 2

    if args.validate_only:
        LOGGER.info("Validated %d parity scenarios", len(scenarios))
        return 0

    environment = os.environ.copy()
    environment["CNS_PRODUCTION_RELEASE"] = "1" if args.production else "0"
    if args.production and (
        not environment.get("CNS_CODESIGN_IDENTITY") or not environment.get("APPLE_TEAM_ID")
    ):
        LOGGER.error("Production acceptance requires CNS_CODESIGN_IDENTITY and APPLE_TEAM_ID")
        return 2

    gates: dict[str, GateResult] = {}
    gates["swift_fast"] = run_gate(
        name="swift_fast",
        command=[str(repo_root / "scripts" / "swift_verify.sh")],
        repo_root=repo_root,
        environment=environment,
    )
    model_requested = environment.get("CNS_RUN_MODEL_TESTS") == "1" and bool(
        environment.get("CNS_WHISPER_MODEL")
    )
    editor_requested = environment.get("CNS_RUN_EDITOR_MODEL_TESTS") == "1" and bool(
        environment.get("CNS_QWEN_MODEL_DIR")
    )
    gates["stt_model"] = GateResult(
        "stt_model",
        "passed" if model_requested and gates["swift_fast"].status == "passed" else "skipped",
        0.0,
        "swift_fast:model-gated-stt",
        None if model_requested else "CNS_RUN_MODEL_TESTS/CNS_WHISPER_MODEL not supplied",
    )
    gates["editor_model"] = GateResult(
        "editor_model",
        "passed" if editor_requested and gates["swift_fast"].status == "passed" else "skipped",
        0.0,
        "swift_fast:model-gated-editor",
        None if editor_requested else "CNS_RUN_EDITOR_MODEL_TESTS/CNS_QWEN_MODEL_DIR not supplied",
    )

    python_executable = repo_root / "venv" / "bin" / "python"
    if python_executable.is_file():
        gates["data_compat"] = run_gate(
            name="data_compat",
            command=[
                str(python_executable),
                "-m",
                "pytest",
                "-q",
                "tests/parity",
            ],
            repo_root=repo_root,
            environment=environment,
        )
    else:
        gates["data_compat"] = GateResult(
            "data_compat", "failed", 0.0, "tests/parity", "project venv is missing"
        )

    gates["bundle_dev"] = run_gate(
        name="bundle_dev",
        command=[str(repo_root / "scripts" / "swift_build_app.sh"), "release"],
        repo_root=repo_root,
        environment=environment,
    )

    if args.data_copy is not None:
        started = time.monotonic()
        try:
            data_copy = validate_data_copy(args.data_copy, repo_root)
            _, detail = audit_data_copy(data_copy)
            gates["data_copy_audit"] = GateResult(
                "data_copy_audit",
                "passed",
                time.monotonic() - started,
                "explicit-data-copy",
                detail,
            )
        except (OSError, ValueError, json.JSONDecodeError) as error:
            gates["data_copy_audit"] = GateResult(
                "data_copy_audit",
                "failed",
                time.monotonic() - started,
                "explicit-data-copy",
                str(error),
            )

    scenario_results = [scenario_result(item, gates, manual) for item in scenarios]
    counts = {
        status: sum(result["status"] == status for result in scenario_results)
        for status in sorted(VALID_STATUSES)
    }
    critical_skips = [
        result["id"]
        for result in scenario_results
        if result["release_critical"] and result["status"] == "skipped"
    ]
    critical_failures = [
        result["id"]
        for result in scenario_results
        if result["release_critical"] and result["status"] == "failed"
    ]
    gate_failures = [gate.name for gate in gates.values() if gate.status == "failed"]
    strict_incomplete = bool(critical_skips) and not args.automated_only
    decision = "go" if not critical_failures and not gate_failures and not critical_skips else "no-go"
    summary = {
        "schema_version": 1,
        "candidate": "swift",
        "generated_at_epoch_seconds": int(time.time()),
        "mode": "automated-only" if args.automated_only else "full-acceptance",
        "production_signing_required": args.production,
        "decision": decision,
        "counts": counts,
        "critical_failures": critical_failures,
        "critical_skips": critical_skips,
        "gates": [asdict(gate) for gate in gates.values()],
        "scenarios": scenario_results,
    }
    write_summary(output_path, summary)
    LOGGER.info("Acceptance summary: %s", output_path)
    LOGGER.info("Decision: %s (%s)", decision, counts)
    if critical_failures or gate_failures or strict_incomplete:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
