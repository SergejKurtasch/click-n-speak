"""Non-destructive acceptance orchestration for the Swift cutover candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import platform
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import asdict, dataclass, replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Mapping, Sequence


LOGGER = logging.getLogger("swift_acceptance")
VALID_STATUSES = {"passed", "failed", "skipped", "missing_prerequisite"}
VALID_CLASSIFICATIONS = {"automated", "manual", "hybrid"}
EVIDENCE_SCHEMA_VERSION = 2
BACKUP_MANIFEST_NAME = "backup_manifest.json"
DATASET_COPY_NAME = "clicknspeak_dataset.jsonl"


@dataclass(frozen=True)
class GateResult:
    name: str
    status: str
    duration_seconds: float
    evidence: str
    detail: str | None = None
    candidate: dict[str, Any] | None = None
    evidence_sha256: str | None = None
    completed_at: str | None = None
    operator: str = "acceptance-runner"


def sha256_path(path: Path) -> str:
    """Return a deterministic SHA-256 for a file or an application bundle."""
    if not path.exists() and not path.is_symlink():
        raise ValueError(f"Artifact does not exist: {path}")
    if path.is_file():
        return _file_sha256(path)
    if not path.is_dir():
        raise ValueError(f"Artifact is neither a file nor a directory: {path}")
    root = path.resolve(strict=True)
    entries: list[dict[str, Any]] = []
    for item in sorted(path.rglob("*"), key=lambda candidate: candidate.relative_to(path).as_posix()):
        relative = item.relative_to(path).as_posix()
        info = item.lstat()
        mode = stat.S_IMODE(info.st_mode)
        if item.is_symlink():
            target = item.resolve(strict=True)
            try:
                target.relative_to(root)
            except ValueError as error:
                raise ValueError(f"Artifact symlink escapes bundle: {relative}") from error
            entries.append({"kind": "symlink", "path": relative, "mode": mode, "target": os.readlink(item)})
        elif item.is_file():
            before = item.stat()
            content_digest = _file_sha256(item)
            after = item.stat()
            if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
                raise ValueError(f"Artifact mutated while hashing: {relative}")
            entries.append(
                {"kind": "file", "path": relative, "mode": mode, "size": before.st_size, "sha256": content_digest}
            )
        elif item.is_dir():
            entries.append({"kind": "directory", "path": relative, "mode": mode})
        else:
            raise ValueError(f"Unsupported artifact entry: {relative}")
    if not entries:
        raise ValueError(f"Artifact directory is empty: {path}")
    digest = hashlib.sha256()
    for entry in entries:
        encoded = json.dumps(entry, sort_keys=True, separators=(",", ":")).encode("utf-8")
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)
    return digest.hexdigest()


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def artifact_identity(path: Path) -> dict[str, str]:
    resolved = path.expanduser().resolve()
    return {"path": str(resolved), "sha256": sha256_path(resolved)}


def build_candidate_identity(
    *,
    git_revision: str,
    version: str,
    app_path: Path,
    dmg_path: Path,
    model_revisions: Mapping[str, str],
    model_artifacts: Mapping[str, Path] | None = None,
    os_version: str,
    hardware: str,
) -> dict[str, Any]:
    """Create the immutable candidate identifiers shared by every gate."""
    if not re.fullmatch(r"[0-9a-f]{7,64}", git_revision):
        raise ValueError("Candidate git revision must be an exact hexadecimal commit revision")
    if not version.strip() or not os_version.strip() or not hardware.strip():
        raise ValueError("Candidate identifiers must be non-empty")
    if not model_revisions or not all(
        isinstance(name, str) and name.strip() and isinstance(value, str) and value.strip()
        for name, value in model_revisions.items()
    ):
        raise ValueError("Model revisions must be a non-empty string mapping")
    if model_artifacts and not set(model_artifacts).issubset(model_revisions):
        raise ValueError("Model artifacts require corresponding model revisions")
    return {
        "git_revision": git_revision,
        "version": version,
        "app": artifact_identity(app_path),
        "dmg": artifact_identity(dmg_path),
        "model_revisions": dict(sorted(model_revisions.items())),
        "model_artifacts": {
            name: artifact_identity(model_path)
            for name, model_path in sorted((model_artifacts or {}).items())
        },
        "os": os_version,
        "hardware": hardware,
    }


def validate_candidate_identity(candidate: Mapping[str, Any]) -> None:
    required = {"git_revision", "version", "app", "dmg", "model_revisions", "model_artifacts", "os", "hardware"}
    if set(candidate) != required:
        raise ValueError("Candidate identity has unsupported or missing fields")
    for name in ("git_revision", "version", "os", "hardware"):
        if not isinstance(candidate[name], str) or not candidate[name].strip():
            raise ValueError(f"Candidate {name} must be a non-empty string")
    if not re.fullmatch(r"[0-9a-f]{7,64}", candidate["git_revision"]):
        raise ValueError("Candidate git revision is invalid")
    revisions = candidate["model_revisions"]
    if not isinstance(revisions, dict) or not revisions or not all(
        isinstance(name, str) and name.strip() and isinstance(value, str) and value.strip()
        for name, value in revisions.items()
    ):
        raise ValueError("Candidate model_revisions must be a string mapping")
    model_artifacts = candidate["model_artifacts"]
    if not isinstance(model_artifacts, dict) or not set(model_artifacts).issubset(revisions):
        raise ValueError("Candidate model_artifacts must match model revisions")
    artifacts = {"app": candidate["app"], "dmg": candidate["dmg"]}
    artifacts.update({f"model {name}": artifact for name, artifact in model_artifacts.items()})
    for name, artifact in artifacts.items():
        if not isinstance(artifact, dict) or set(artifact) != {"path", "sha256"}:
            raise ValueError(f"Candidate {name} artifact is invalid")
        if not isinstance(artifact["path"], str) or not artifact["path"].strip():
            raise ValueError(f"Candidate {name} artifact path is invalid")
        if not _is_sha256(artifact["sha256"]):
            raise ValueError(f"Candidate {name} SHA-256 is invalid")


def verify_artifact(artifact: Mapping[str, Any], *, label: str) -> Path:
    if set(artifact) != {"path", "sha256"}:
        raise ValueError(f"{label} must contain path and sha256")
    path_value = artifact.get("path")
    expected_checksum = artifact.get("sha256")
    if not isinstance(path_value, str) or not path_value.strip():
        raise ValueError(f"{label} path is invalid")
    if not _is_sha256(expected_checksum):
        raise ValueError(f"{label} checksum is invalid")
    path = Path(path_value).expanduser().resolve()
    if sha256_path(path) != expected_checksum:
        raise ValueError(f"{label} checksum does not match: {path}")
    return path


def verify_candidate_artifacts(candidate: Mapping[str, Any]) -> None:
    validate_candidate_identity(candidate)
    verify_artifact(candidate["app"], label="Candidate app")
    verify_artifact(candidate["dmg"], label="Candidate DMG")
    for name, artifact in candidate["model_artifacts"].items():
        verify_artifact(artifact, label=f"Candidate model {name}")


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and bool(re.fullmatch(r"[0-9a-f]{64}", value))


def build_gate_environment(*, production: bool, base: Mapping[str, str] | None = None) -> dict[str, str]:
    environment = dict(os.environ if base is None else base)
    environment["CNS_PRODUCTION_RELEASE"] = "1" if production else "0"
    environment["CNS_RESET_TCC_AFTER_BUILD"] = "0"
    return environment


def missing_prerequisite_gate(name: str, detail: str) -> GateResult:
    return GateResult(name, "missing_prerequisite", 0.0, "", detail)


def gate_log_path(output_path: Path, gate_name: str, run_id: str) -> Path:
    safe_name = gate_name.replace("/", "_")
    return output_path.parent / "runs" / run_id / "gates" / f"{safe_name}.log"


def scenario_gate_command(repo_root: Path, test_targets: Sequence[str]) -> list[str]:
    target = test_targets[0]
    path_text, marker, selector = target.partition("#")
    if marker and not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", selector):
        raise ValueError(f"Scenario target has an invalid test selector: {target}")
    root = repo_root.resolve()
    try:
        target_path = (root / path_text).resolve(strict=True)
    except OSError as error:
        raise ValueError(f"Scenario target does not exist: {target}") from error
    try:
        relative = target_path.relative_to(root)
    except ValueError as error:
        raise ValueError(f"Scenario target escapes repository: {target}") from error
    if not target_path.is_file():
        raise ValueError(f"Scenario target is not a file: {target}")
    parts = relative.parts
    if parts and parts[0] == "tests" and target_path.suffix == ".py":
        selected = f"{relative}::{selector}" if marker else str(relative)
        return [sys.executable, "-m", "pytest", "-q", selected]
    if len(parts) >= 2 and parts[0] == "Packages":
        if len(parts) < 4 or parts[2] != "Tests" or target_path.suffix != ".swift":
            raise ValueError(f"Swift scenario target must be an exact test source: {target}")
        package = root / parts[0] / parts[1]
    elif parts and parts[0] == "ClickNSpeak":
        if len(parts) < 3 or parts[1] != "Tests" or target_path.suffix != ".swift":
            raise ValueError(f"Swift scenario target must be an exact test source: {target}")
        package = root / "ClickNSpeak"
    else:
        raise ValueError(f"Unsupported scenario test target: {target}")
    return [
        "swift",
        "test",
        "--disable-index-store",
        "--package-path",
        str(package),
        "--filter",
        selector if marker else target_path.stem,
    ]


def current_git_revision(repo_root: Path) -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )
    revision = completed.stdout.strip()
    if completed.returncode != 0 or not revision:
        raise ValueError("Could not determine the current git revision")
    return revision


def require_clean_checkout(repo_root: Path) -> None:
    completed = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=repo_root,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0 or completed.stdout.strip():
        raise ValueError("Acceptance requires a clean checkout at the exact candidate revision")


def project_version(repo_root: Path) -> str:
    with (repo_root / "ClickNSpeak" / "Info.plist").open("rb") as handle:
        bundle = plistlib.load(handle)
    version = bundle.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not version:
        raise ValueError("Could not determine the native application version")
    return version


def candidate_from_arguments(args: argparse.Namespace, repo_root: Path) -> dict[str, Any]:
    if args.candidate_dmg is None or args.candidate_release_manifest is None:
        raise ValueError("Acceptance requires --candidate-dmg and --candidate-release-manifest")
    try:
        model_revisions = json.loads(args.candidate_model_revisions)
    except json.JSONDecodeError as error:
        raise ValueError("--candidate-model-revisions must be a JSON object") from error
    if not isinstance(model_revisions, dict):
        raise ValueError("--candidate-model-revisions must be a JSON object")
    model_paths = {
        "whisper": os.environ.get("CNS_WHISPER_MODEL"),
        "qwen": os.environ.get("CNS_QWEN_MODEL_DIR"),
    }
    model_artifacts = {
        name: (Path(value) if Path(value).is_absolute() else repo_root / value)
        for name, value in model_paths.items()
        if value and (Path(value) if Path(value).is_absolute() else repo_root / value).exists()
    }
    app_path = args.candidate_app if args.candidate_app.is_absolute() else repo_root / args.candidate_app
    dmg_path = args.candidate_dmg if args.candidate_dmg.is_absolute() else repo_root / args.candidate_dmg
    manifest_path = (
        args.candidate_release_manifest
        if args.candidate_release_manifest.is_absolute()
        else repo_root / args.candidate_release_manifest
    )
    require_clean_checkout(repo_root)
    candidate = build_candidate_identity(
        git_revision=current_git_revision(repo_root),
        version=args.candidate_version or project_version(repo_root),
        app_path=app_path,
        dmg_path=dmg_path,
        model_revisions=model_revisions,
        model_artifacts=model_artifacts,
        os_version=args.candidate_os or platform.mac_ver()[0] or platform.platform(),
        hardware=args.candidate_hardware or platform.machine(),
    )
    _validate_release_manifest(manifest_path, candidate)
    verify_dmg_application(candidate)
    return candidate


def verify_dmg_application(candidate: Mapping[str, Any]) -> None:
    """Prove that the distributed image contains the exact accepted app tree."""
    mount_path = Path(tempfile.mkdtemp(prefix="clicknspeak-acceptance-"))
    mounted = False
    try:
        attached = subprocess.run(
            ["hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", str(mount_path),
             candidate["dmg"]["path"]],
            check=False,
            capture_output=True,
        )
        if attached.returncode != 0:
            raise ValueError("Candidate DMG could not be mounted read-only")
        mounted = True
        packaged_app = mount_path / "Click-n-speak.app"
        if not packaged_app.is_dir() or sha256_path(packaged_app) != candidate["app"]["sha256"]:
            raise ValueError("Candidate DMG does not contain the exact candidate app")
    finally:
        if mounted:
            detached = subprocess.run(
                ["hdiutil", "detach", "-quiet", str(mount_path)],
                check=False,
                capture_output=True,
            )
            if detached.returncode != 0:
                raise ValueError("Candidate DMG could not be detached after verification")
        if mount_path.exists():
            mount_path.rmdir()


def _validate_release_manifest(path: Path, candidate: Mapping[str, Any]) -> None:
    manifest = load_json_object(path)
    if manifest.get("schema_version") != 1:
        raise ValueError("Candidate release manifest schema is unsupported")
    if manifest.get("git_revision") != candidate["git_revision"]:
        raise ValueError("Candidate release manifest git revision does not match")
    dmg = manifest.get("dmg")
    if not isinstance(dmg, dict):
        raise ValueError("Candidate release manifest does not describe a DMG")
    if manifest.get("version") != candidate["version"]:
        raise ValueError("Candidate release manifest version does not match app bundle")
    if dmg.get("sha256") != candidate["dmg"]["sha256"]:
        raise ValueError("Candidate release manifest DMG checksum does not match")
    if dmg.get("file_name") != Path(candidate["dmg"]["path"]).name:
        raise ValueError("Candidate release manifest DMG filename does not match")
    if dmg.get("size") != Path(candidate["dmg"]["path"]).stat().st_size:
        raise ValueError("Candidate release manifest DMG size does not match")
    info_path = Path(candidate["app"]["path"]) / "Contents" / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            bundle_info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ValueError("Candidate app Info.plist is unreadable") from error
    if bundle_info.get("CFBundleShortVersionString") != candidate["version"]:
        raise ValueError("Candidate app bundle version does not match")
    if bundle_info.get("CNSGitRevision") != candidate["git_revision"]:
        raise ValueError("Candidate app bundle git revision does not match")


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
        if not isinstance(scenario_id, str) or not scenario_id.strip():
            raise ValueError("Scenario ID must be a non-empty string")
        if scenario_id in seen:
            raise ValueError(f"Duplicate scenario ID: {scenario_id}")
        seen.add(scenario_id)
        if not isinstance(raw["classification"], str) or raw["classification"] not in VALID_CLASSIFICATIONS:
            raise ValueError(f"Invalid classification for {scenario_id}")
        if not isinstance(raw["release_critical"], bool):
            raise ValueError(f"release_critical must be Boolean for {scenario_id}")
        if not isinstance(raw["fixture_ids"], list) or not all(
            isinstance(fixture_id, str) and fixture_id.strip() for fixture_id in raw["fixture_ids"]
        ):
            raise ValueError(f"fixture_ids must be a list for {scenario_id}")
        if raw["classification"] == "automated":
            targets = raw.get("test_targets")
            regression_ids = raw.get("regression_ids")
            if not isinstance(targets, list) or not targets:
                raise ValueError(f"test_targets must be a non-empty list for {scenario_id}")
            if not all(isinstance(target, str) and target for target in targets):
                raise ValueError(f"test_targets must contain non-empty strings for {scenario_id}")
            if not isinstance(regression_ids, list) or not all(
                isinstance(regression_id, str) and regression_id.startswith("R")
                for regression_id in regression_ids
            ):
                raise ValueError(f"regression_ids must contain R-prefixed IDs for {scenario_id}")
            if raw["evidence_gate"] == "swift_fast":
                raise ValueError(f"Automated scenario {scenario_id} cannot use only the fast prerequisite")
        required = raw["required"]
        if not isinstance(required, dict) or set(required) != {
            "signed_app",
            "permissions",
            "models",
            "network",
        }:
            raise ValueError(f"Invalid requirements object for {scenario_id}")
        if not isinstance(required["signed_app"], bool) or not isinstance(required["network"], bool):
            raise ValueError(f"Invalid Boolean requirements for {scenario_id}")
        for name in ("permissions", "models"):
            if not isinstance(required[name], list) or not all(
                isinstance(value, str) and value.strip() for value in required[name]
            ):
                raise ValueError(f"Invalid {name} requirements for {scenario_id}")
        validated.append(raw)
    return validated


def load_manual_evidence(
    path: Path | None,
    *,
    expected_candidate: Mapping[str, Any] | None = None,
) -> dict[str, dict[str, Any]]:
    if path is None:
        return {}
    payload = load_json_object(path)
    if payload.get("schema_version") != EVIDENCE_SCHEMA_VERSION:
        raise ValueError("Unsupported manual evidence schema")
    candidate = payload.get("candidate")
    if not isinstance(candidate, dict):
        raise ValueError("Manual evidence must contain a candidate identity")
    validate_candidate_identity(candidate)
    if expected_candidate is not None:
        validate_candidate_identity(expected_candidate)
        if candidate != expected_candidate:
            raise ValueError("Manual evidence belongs to a different candidate")
        verify_candidate_artifacts(expected_candidate)
        evidence_not_before = max(
            Path(expected_candidate[name]["path"]).stat().st_mtime for name in ("app", "dmg")
        )
    else:
        evidence_not_before = None
    raw_results = payload.get("results")
    if not isinstance(raw_results, dict):
        raise ValueError("Manual evidence must contain a results object")
    results: dict[str, dict[str, Any]] = {}
    for scenario_id, result in raw_results.items():
        if not isinstance(result, dict) or not isinstance(result.get("status"), str) or result["status"] not in VALID_STATUSES:
            raise ValueError(f"Invalid manual evidence for {scenario_id}")
        if result["status"] == "passed":
            operator = result.get("operator")
            completed_at = result.get("completed_at")
            artifact = result.get("artifact")
            if not isinstance(operator, str) or not operator:
                raise ValueError(f"Passed manual evidence needs an operator: {scenario_id}")
            if not isinstance(completed_at, str) or not completed_at:
                raise ValueError(f"Passed manual evidence needs completion time: {scenario_id}")
            if not isinstance(artifact, dict):
                raise ValueError(f"Passed manual evidence needs an artifact: {scenario_id}")
            artifact_path = verify_artifact(artifact, label=f"Manual evidence artifact for {scenario_id}")
            if not artifact_path.is_file() or artifact_path.stat().st_size == 0:
                raise ValueError(f"Passed manual evidence needs a non-empty file: {scenario_id}")
            completed = _parse_completed_at(completed_at, evidence_not_before)
            if artifact_path.suffix == ".json":
                structured = load_json_object(artifact_path)
                if structured.get("status") != "passed":
                    raise ValueError(f"Structured evidence status is not passed: {scenario_id}")
            stored = dict(result)
            stored["evidence"] = str(artifact_path)
            stored["completed_at"] = completed.isoformat()
            results[str(scenario_id)] = stored
        else:
            results[str(scenario_id)] = dict(result)
    return results


def _parse_completed_at(value: str, evidence_not_before: float | None) -> datetime:
    try:
        completed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("Evidence completion time is malformed") from error
    if completed.tzinfo is None or completed.utcoffset() is None:
        raise ValueError("Evidence completion time must include a timezone")
    now = datetime.now(UTC)
    if completed > now + timedelta(minutes=5):
        raise ValueError("Evidence completion time is in the future")
    if evidence_not_before is not None and completed.timestamp() < evidence_not_before:
        raise ValueError("Evidence completion time predates candidate artifacts")
    return completed.astimezone(UTC)


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
    dataset = path / DATASET_COPY_NAME
    if dataset.is_symlink() or not dataset.is_file():
        raise ValueError(f"Data copy requires {DATASET_COPY_NAME}")
    dataset_rows = 0
    with dataset.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if line.strip():
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ValueError(f"{DATASET_COPY_NAME}:{line_number} is not a JSON object")
                if not isinstance(value.get("raw_whisper"), str) or not value["raw_whisper"].strip():
                    raise ValueError(f"{DATASET_COPY_NAME}:{line_number} has no usable raw_whisper")
                dataset_rows += 1
    if dataset_rows == 0:
        raise ValueError(f"Data copy {DATASET_COPY_NAME} is empty")
    checked.append(DATASET_COPY_NAME)

    manifest_path = path / BACKUP_MANIFEST_NAME
    if not manifest_path.is_file():
        raise ValueError(f"Data copy requires {BACKUP_MANIFEST_NAME}")
    manifest = load_json_object(manifest_path)
    files = manifest.get("files")
    if manifest.get("schema_version") != 1 or not isinstance(files, list) or not files:
        raise ValueError(f"{BACKUP_MANIFEST_NAME} is malformed")
    names: set[str] = set()
    for entry in files:
        if not isinstance(entry, dict) or set(entry) != {"name", "sha256", "size"}:
            raise ValueError(f"{BACKUP_MANIFEST_NAME} has an invalid entry")
        name = entry["name"]
        if not isinstance(name, str) or not name or Path(name).name != name or name in {".", ".."}:
            raise ValueError(f"{BACKUP_MANIFEST_NAME} has an unsafe entry name")
        if name in names:
            raise ValueError(f"{BACKUP_MANIFEST_NAME} has duplicate entry names")
        names.add(name)
        copied = path / name
        if copied.is_symlink() or not copied.is_file():
            raise ValueError(f"{BACKUP_MANIFEST_NAME} references a missing or unsafe file")
        if not isinstance(entry["size"], int) or entry["size"] < 0 or copied.stat().st_size != entry["size"]:
            raise ValueError(f"{BACKUP_MANIFEST_NAME} size does not match {name}")
        if not _is_sha256(entry["sha256"]) or sha256_path(copied) != entry["sha256"]:
            raise ValueError(f"{BACKUP_MANIFEST_NAME} checksum does not match {name}")
    required_names = {DATASET_COPY_NAME, "config.json", "corrections.json"}
    missing_names = sorted(required_names - names)
    if missing_names:
        raise ValueError(f"{BACKUP_MANIFEST_NAME} does not inventory {', '.join(missing_names)}")
    checked.append(BACKUP_MANIFEST_NAME)

    config = path / "config.json"
    if not config.is_file() or config.is_symlink():
        raise ValueError("Data copy requires config.json")
    load_json_object(config)
    checked.append("config.json")
    corrections = path / "corrections.json"
    if not corrections.is_file() or corrections.is_symlink():
        raise ValueError("Data copy requires corrections.json")
    load_json_object(corrections)
    checked.append("corrections.json")
    for name in ("metrics_history.jsonl",):
        candidate = path / name
        if not candidate.exists():
            continue
        if candidate.is_symlink() or not candidate.is_file():
            raise ValueError(f"Unsafe optional data copy file: {name}")
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
    log_path: Path,
) -> GateResult:
    started = time.monotonic()
    LOGGER.info("Running gate %s", name)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("x", encoding="utf-8") as log_handle:
        completed = subprocess.run(
            list(command),
            cwd=repo_root,
            env=dict(environment),
            check=False,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
        )
    duration = time.monotonic() - started
    if completed.returncode == 0:
        return GateResult(
            name,
            "passed",
            duration,
            str(log_path),
            evidence_sha256=sha256_path(log_path),
            completed_at=datetime.now(UTC).isoformat(),
        )
    return GateResult(
        name,
        "failed",
        duration,
        str(log_path),
        f"command exited with status {completed.returncode}",
        evidence_sha256=sha256_path(log_path),
        completed_at=datetime.now(UTC).isoformat(),
    )


def run_scenario_gate(
    *,
    name: str,
    test_targets: Sequence[str],
    repo_root: Path,
    environment: Mapping[str, str],
    log_path: Path,
) -> GateResult:
    """Run every declared scenario target so a fast prerequisite cannot imply coverage."""
    started = time.monotonic()
    LOGGER.info("Running scenario gate %s", name)
    commands = [(target, scenario_gate_command(repo_root, [target])) for target in test_targets]
    log_path.parent.mkdir(parents=True, exist_ok=True)
    failure: str | None = None
    with log_path.open("x", encoding="utf-8") as log_handle:
        for target, command in commands:
            completed = subprocess.run(
                command,
                cwd=repo_root,
                env=dict(environment),
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            output = completed.stdout if isinstance(completed.stdout, str) else ""
            log_handle.write(f"target: {target}\n")
            log_handle.write(output)
            log_handle.flush()
            if completed.returncode != 0:
                failure = f"target {target} exited with status {completed.returncode}"
                break
            if not _selected_tests_executed(output, command):
                failure = f"target {target} did not execute a selected test"
                break
    return GateResult(
        name,
        "failed" if failure else "passed",
        time.monotonic() - started,
        str(log_path),
        failure,
        evidence_sha256=sha256_path(log_path),
        completed_at=datetime.now(UTC).isoformat(),
    )


def _selected_tests_executed(output: str, command: Sequence[str]) -> bool:
    if command[0] == "swift":
        patterns = (r"Executed ([1-9][0-9]*) tests?", r"Test run with ([1-9][0-9]*) tests?")
    else:
        patterns = (r"(?:^|\s)([1-9][0-9]*) passed\b",)
    return any(re.search(pattern, output) for pattern in patterns)


def scenario_result(
    scenario: Mapping[str, Any],
    gates: Mapping[str, GateResult],
    manual: Mapping[str, Mapping[str, Any]],
    candidate: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    scenario_id = str(scenario["id"])
    classification = str(scenario["classification"])
    gate_name = scenario.get("evidence_gate")
    gate = gates.get(str(gate_name)) if gate_name else None
    manual_result = manual.get(scenario_id)

    if classification == "automated":
        status = gate.status if gate and gate.status in VALID_STATUSES else "skipped"
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
        elif gate and gate.status == "missing_prerequisite":
            status = "missing_prerequisite"
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

    result = {
        "id": scenario_id,
        "area": scenario["area"],
        "classification": classification,
        "release_critical": scenario["release_critical"],
        "status": status,
        "evidence": evidence,
        "detail": detail,
        "intentional_deviation": scenario["intentional_deviation"],
    }
    if classification == "automated" and candidate is not None:
        result["candidate"] = dict(candidate)
    if gate is not None:
        result["evidence_sha256"] = gate.evidence_sha256
        result["completed_at"] = gate.completed_at
        result["operator"] = gate.operator
    if manual_result is not None and classification != "automated":
        result["operator"] = manual_result.get("operator")
        result["completed_at"] = manual_result.get("completed_at")
        artifact = manual_result.get("artifact")
        if isinstance(artifact, dict):
            result["evidence_sha256"] = artifact.get("sha256")
        if candidate is not None:
            result["candidate"] = dict(candidate)
    return result


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
    parser.add_argument(
        "--candidate-app",
        type=Path,
        default=Path("dist/swift/Click-n-speak.app"),
        help="Built application bundle whose checksum is recorded in acceptance evidence.",
    )
    parser.add_argument(
        "--candidate-dmg",
        type=Path,
        help="DMG artifact whose checksum is recorded in acceptance evidence.",
    )
    parser.add_argument(
        "--candidate-release-manifest",
        type=Path,
        help="Release manifest generated for the exact candidate app and DMG.",
    )
    parser.add_argument(
        "--candidate-version",
        help="Release version; defaults to ClickNSpeak/Info.plist.",
    )
    parser.add_argument(
        "--candidate-model-revisions",
        default="{}",
        help="JSON mapping of each shipped model to its immutable revision.",
    )
    parser.add_argument("--candidate-os", help="Observed macOS version for this candidate.")
    parser.add_argument("--candidate-hardware", help="Observed hardware for this candidate.")
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    manifest_path = args.manifest if args.manifest.is_absolute() else repo_root / args.manifest
    output_path = args.output if args.output.is_absolute() else repo_root / args.output
    run_id = uuid.uuid4().hex
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

    try:
        candidate = candidate_from_arguments(args, repo_root)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        LOGGER.error("Candidate prerequisite validation failed: %s", error)
        return 2

    environment = build_gate_environment(production=args.production)
    if args.production and (
        not environment.get("CNS_CODESIGN_IDENTITY") or not environment.get("APPLE_TEAM_ID")
    ):
        LOGGER.error("Production acceptance requires CNS_CODESIGN_IDENTITY and APPLE_TEAM_ID")
        return 2

    gates: dict[str, GateResult] = {}
    fast_environment = dict(environment)
    fast_environment["CNS_RUN_MODEL_TESTS"] = "0"
    fast_environment["CNS_RUN_EDITOR_MODEL_TESTS"] = "0"
    gates["swift_fast"] = run_gate(
        name="swift_fast",
        command=[str(repo_root / "scripts" / "swift_verify.sh")],
        repo_root=repo_root,
        environment=fast_environment,
        log_path=gate_log_path(output_path, "swift_fast", run_id),
    )
    whisper_model = environment.get("CNS_WHISPER_MODEL", "")
    golden_dir = environment.get("CNS_STT_GOLDEN_DIR", str(repo_root / "spikes/stt-bakeoff/golden"))
    qwen_model = environment.get("CNS_QWEN_MODEL_DIR", "")
    whisper_path = repo_root / whisper_model if whisper_model else repo_root / "__missing_whisper_model__"
    golden_path = repo_root / golden_dir
    qwen_path = repo_root / qwen_model if qwen_model else repo_root / "__missing_qwen_model__"
    model_requested = (
        environment.get("CNS_RUN_MODEL_TESTS") == "1"
        and whisper_path.is_file()
        and (golden_path / "manifest.jsonl").is_file()
        and (golden_path / "audio_16k").is_dir()
    )
    editor_requested = (
        environment.get("CNS_RUN_EDITOR_MODEL_TESTS") == "1"
        and all((qwen_path / name).is_file() for name in ("config.json", "tokenizer.json", "model.safetensors"))
    )
    if not model_requested:
        gates["stt_model"] = missing_prerequisite_gate(
            "stt_model", "CNS_RUN_MODEL_TESTS=1 and CNS_WHISPER_MODEL are required"
        )
    elif gates["swift_fast"].status != "passed":
        gates["stt_model"] = GateResult(
            "stt_model", "failed", 0.0, "", "swift_fast prerequisite failed"
        )
    else:
        stt_environment = dict(environment)
        stt_environment["CNS_RUN_EDITOR_MODEL_TESTS"] = "0"
        gates["stt_model"] = run_gate(
            name="stt_model",
            command=["bash", str(repo_root / "scripts" / "swift_verify_stt_model.sh")],
            repo_root=repo_root,
            environment=stt_environment,
            log_path=gate_log_path(output_path, "stt_model", run_id),
        )
    if not editor_requested:
        gates["editor_model"] = missing_prerequisite_gate(
            "editor_model", "CNS_RUN_EDITOR_MODEL_TESTS=1 and CNS_QWEN_MODEL_DIR are required"
        )
    elif gates["swift_fast"].status != "passed":
        gates["editor_model"] = GateResult(
            "editor_model", "failed", 0.0, "", "swift_fast prerequisite failed"
        )
    else:
        editor_environment = dict(environment)
        editor_environment["CNS_RUN_MODEL_TESTS"] = "0"
        gates["editor_model"] = run_gate(
            name="editor_model",
            command=["bash", str(repo_root / "scripts" / "swift_verify_editor_model.sh")],
            repo_root=repo_root,
            environment=editor_environment,
            log_path=gate_log_path(output_path, "editor_model", run_id),
        )

    gates["data_compat"] = run_gate(
        name="data_compat",
        command=[
            "swift",
            "test",
            "--disable-index-store",
            "--package-path",
            str(repo_root / "Packages" / "CNSCore"),
            "--filter",
            "ParityDataCompatibilityTests",
        ],
        repo_root=repo_root,
        environment=environment,
        log_path=gate_log_path(output_path, "data_compat", run_id),
    )

    gates["bundle_dev"] = run_gate(
        name="bundle_dev",
        command=[str(repo_root / "scripts" / "swift_verify_bundle.sh"), candidate["app"]["path"]],
        repo_root=repo_root,
        environment=environment,
        log_path=gate_log_path(output_path, "bundle_dev", run_id),
    )

    if gates["bundle_dev"].status == "passed":
        try:
            verify_candidate_artifacts(candidate)
            gates["candidate_artifacts"] = GateResult(
                "candidate_artifacts",
                "passed",
                0.0,
                str(args.candidate_app),
                "verified app and DMG candidate checksums",
                candidate,
            )
        except (OSError, ValueError, json.JSONDecodeError) as error:
            gates["candidate_artifacts"] = GateResult(
                "candidate_artifacts", "failed", 0.0, "", str(error)
            )
    else:
        gates["candidate_artifacts"] = GateResult(
            "candidate_artifacts", "failed", 0.0, "", "bundle_dev prerequisite failed"
        )

    gates = {name: replace(gate, candidate=candidate) for name, gate in gates.items()}
    if evidence_path is not None:
        try:
            manual = load_manual_evidence(evidence_path, expected_candidate=candidate)
        except (OSError, ValueError, json.JSONDecodeError) as error:
            manual = {}
            gates["manual_evidence"] = GateResult(
                "manual_evidence", "failed", 0.0, str(evidence_path), str(error), candidate
            )

    for scenario in scenarios:
        gate_name = str(scenario["evidence_gate"])
        if scenario["classification"] != "automated" or not gate_name.startswith("scenario."):
            continue
        if gates["swift_fast"].status != "passed":
            gates[gate_name] = GateResult(
                gate_name, "failed", 0.0, "", "swift_fast prerequisite failed"
            )
            continue
        try:
            gates[gate_name] = run_scenario_gate(
                name=gate_name,
                test_targets=scenario["test_targets"],
                repo_root=repo_root,
                environment=environment,
                log_path=gate_log_path(output_path, gate_name, run_id),
            )
        except ValueError as error:
            gates[gate_name] = GateResult(gate_name, "failed", 0.0, "", str(error))

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

    try:
        verify_candidate_artifacts(candidate)
        require_clean_checkout(repo_root)
        if current_git_revision(repo_root) != candidate["git_revision"]:
            raise ValueError("Candidate git revision changed during acceptance")
    except (OSError, ValueError) as error:
        gates["candidate_artifacts"] = GateResult(
            "candidate_artifacts", "failed", 0.0, "", str(error), candidate
        )
    gates = {name: replace(gate, candidate=candidate) for name, gate in gates.items()}
    scenario_results = [scenario_result(item, gates, manual, candidate) for item in scenarios]
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
    critical_missing_prerequisites = [
        result["id"]
        for result in scenario_results
        if result["release_critical"] and result["status"] == "missing_prerequisite"
    ]
    gate_failures = [gate.name for gate in gates.values() if gate.status == "failed"]
    gate_missing_prerequisites = [
        gate.name for gate in gates.values() if gate.status == "missing_prerequisite"
    ]
    strict_incomplete = bool(critical_skips or critical_missing_prerequisites) and not args.automated_only
    decision = (
        "go"
        if not critical_failures and not gate_failures and not critical_skips
        and not critical_missing_prerequisites and not gate_missing_prerequisites
        else "no-go"
    )
    summary = {
        "schema_version": 2,
        "candidate": candidate,
        "generated_at_epoch_seconds": int(time.time()),
        "mode": "automated-only" if args.automated_only else "full-acceptance",
        "production_signing_required": args.production,
        "decision": decision,
        "counts": counts,
        "critical_failures": critical_failures,
        "critical_skips": critical_skips,
        "critical_missing_prerequisites": critical_missing_prerequisites,
        "missing_prerequisites": gate_missing_prerequisites,
        "gates": [asdict(gate) for gate in gates.values()],
        "scenarios": scenario_results,
    }
    write_summary(output_path, summary)
    LOGGER.info("Acceptance summary: %s", output_path)
    LOGGER.info("Decision: %s (%s)", decision, counts)
    if critical_failures or critical_missing_prerequisites or gate_failures or gate_missing_prerequisites or strict_incomplete:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
