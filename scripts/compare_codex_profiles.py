"""Compare privacy-safe aggregate results for two Codex execution profiles."""

from __future__ import annotations

import argparse
import json
import logging
import math
import random
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from statistics import median
from typing import Sequence

LOGGER = logging.getLogger(__name__)
REPO_ROOT = Path(__file__).resolve().parents[1]
PROFILES = frozenset({"efficient", "deep"})
TASK_RESULT_FIELDS = frozenset(
    {
        "profile",
        "task_class",
        "completion",
        "user_corrections",
        "regressions",
        "wall_time_seconds",
        "input_tokens",
        "output_tokens",
    }
)
PROVENANCE_FIELDS = frozenset(
    {
        "repository_revision",
        "working_tree_clean",
        "benchmark_version",
        "fixture_sha256",
        "acceptance_sha256",
        "pairing_seed",
        "run_order",
    }
)
CONTENT_FIELDS = frozenset(
    {
        "content",
        "prompt",
        "session_content",
        "task",
        "task_text",
        "text",
        "transcript",
    }
)
REQUIRED_TASKS_PER_PROFILE = 10
MINIMUM_CLEAN_EFFICIENT_COMPLETIONS = 9
BENCHMARK_VERSION = "1"
REPRESENTATIVE_TASK_CLASSES = frozenset(
    {
        "small_bug_diagnosis",
        "focused_unit_fix",
        "swift_concurrency_review",
        "python_parity_check",
        "config_migration",
        "test_failure_triage",
        "documentation_update",
        "release_script_review",
        "multi_file_refactor_plan",
        "regression_review",
    }
)


@dataclass(frozen=True)
class TaskResult:
    """One task's permitted benchmark metrics, deliberately excluding task content."""

    profile: str
    task_class: str
    completion: bool
    user_corrections: int
    regressions: int
    wall_time_seconds: float
    input_tokens: int
    output_tokens: int


@dataclass(frozen=True)
class BenchmarkProvenance:
    """Privacy-safe evidence that a paired aggregate benchmark is reproducible."""

    repository_revision: str
    working_tree_clean: bool
    benchmark_version: str
    fixture_sha256: str
    acceptance_sha256: str
    pairing_seed: int
    run_order: list[str]


@dataclass(frozen=True)
class ProfileComparison:
    """Aggregate decision and evidence for whether efficient may become the default."""

    efficient_clean_completions: int
    deep_clean_completions: int
    efficient_user_corrections: int
    deep_user_corrections: int
    efficient_regressions: int
    deep_regressions: int
    efficient_median_total_tokens: float
    deep_median_total_tokens: float
    efficient_median_wall_time_seconds: float
    deep_median_wall_time_seconds: float
    promote_efficient: bool


def _validate_task_result(result: TaskResult) -> None:
    if result.profile not in PROFILES:
        raise ValueError(f"Unsupported profile: {result.profile!r}")
    if not result.task_class:
        raise ValueError("task_class must not be empty")
    if not isinstance(result.completion, bool):
        raise ValueError("completion must be a boolean")
    for field_name, value in (
        ("user_corrections", result.user_corrections),
        ("regressions", result.regressions),
        ("input_tokens", result.input_tokens),
        ("output_tokens", result.output_tokens),
    ):
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError(f"{field_name} must be a non-negative integer")
    if (
        not isinstance(result.wall_time_seconds, (int, float))
        or isinstance(result.wall_time_seconds, bool)
        or result.wall_time_seconds < 0
        or not math.isfinite(float(result.wall_time_seconds))
    ):
        raise ValueError("wall_time_seconds must be a finite non-negative number")


def _results_for_profile(results: Sequence[TaskResult], profile: str) -> list[TaskResult]:
    selected = [result for result in results if result.profile == profile]
    if len(selected) != REQUIRED_TASKS_PER_PROFILE:
        raise ValueError(f"{profile} requires exactly {REQUIRED_TASKS_PER_PROFILE} task results")
    classes = [result.task_class for result in selected]
    if len(set(classes)) != len(classes):
        raise ValueError(f"{profile} task classes must be unique")
    if set(classes) != REPRESENTATIVE_TASK_CLASSES:
        raise ValueError(f"{profile} must use the fixed representative task classes")
    return selected


def _clean_completions(results: Sequence[TaskResult]) -> int:
    return sum(result.completion for result in results)


def compare_profiles(results: Sequence[TaskResult]) -> ProfileComparison:
    """Return the deterministic promotion decision for paired aggregate results."""
    for result in results:
        _validate_task_result(result)
    efficient = _results_for_profile(results, "efficient")
    deep = _results_for_profile(results, "deep")
    if {result.task_class for result in efficient} != {result.task_class for result in deep}:
        raise ValueError("Profiles must use the same task classes")

    efficient_clean = _clean_completions(efficient)
    deep_clean = _clean_completions(deep)
    efficient_corrections = sum(result.user_corrections for result in efficient)
    deep_corrections = sum(result.user_corrections for result in deep)
    efficient_regressions = sum(result.regressions for result in efficient)
    deep_regressions = sum(result.regressions for result in deep)
    efficient_tokens = median(result.input_tokens + result.output_tokens for result in efficient)
    deep_tokens = median(result.input_tokens + result.output_tokens for result in deep)
    efficient_wall_time = median(result.wall_time_seconds for result in efficient)
    deep_wall_time = median(result.wall_time_seconds for result in deep)
    promote_efficient = (
        efficient_clean >= MINIMUM_CLEAN_EFFICIENT_COMPLETIONS
        and efficient_corrections <= deep_corrections
        and efficient_regressions <= deep_regressions
        and efficient_tokens < deep_tokens
    )
    return ProfileComparison(
        efficient_clean_completions=efficient_clean,
        deep_clean_completions=deep_clean,
        efficient_user_corrections=efficient_corrections,
        deep_user_corrections=deep_corrections,
        efficient_regressions=efficient_regressions,
        deep_regressions=deep_regressions,
        efficient_median_total_tokens=efficient_tokens,
        deep_median_total_tokens=deep_tokens,
        efficient_median_wall_time_seconds=efficient_wall_time,
        deep_median_wall_time_seconds=deep_wall_time,
        promote_efficient=promote_efficient,
    )


def _parse_result(payload: object) -> TaskResult:
    if not isinstance(payload, dict):
        raise ValueError("Each result must be an object")
    fields = frozenset(payload)
    forbidden = fields & CONTENT_FIELDS
    if forbidden:
        raise ValueError(f"Content-bearing field(s) not permitted: {sorted(forbidden)}")
    if fields != TASK_RESULT_FIELDS:
        missing = TASK_RESULT_FIELDS - fields
        unexpected = fields - TASK_RESULT_FIELDS
        raise ValueError(f"Invalid result fields; missing={sorted(missing)}, unexpected={sorted(unexpected)}")
    return TaskResult(**payload)


def _expected_run_ids(results: Sequence[TaskResult]) -> set[str]:
    return {f"{result.profile}:{result.task_class}" for result in results}


def _deterministic_run_order(seed: int) -> list[str]:
    task_classes = sorted(REPRESENTATIVE_TASK_CLASSES)
    random.Random(seed).shuffle(task_classes)
    return [
        f"{profile}:{task_class}"
        for index, task_class in enumerate(task_classes)
        for profile in (("efficient", "deep") if index % 2 == 0 else ("deep", "efficient"))
    ]


def _validate_run_order(run_order: object, results: Sequence[TaskResult], pairing_seed: int) -> list[str]:
    if not isinstance(run_order, list) or not all(isinstance(item, str) for item in run_order):
        raise ValueError("provenance run_order must be a list of profile:task_class identifiers")
    if set(run_order) != _expected_run_ids(results) or len(run_order) != len(results):
        raise ValueError("provenance run_order must include every profile/task pair exactly once")
    if len(run_order) % 2:
        raise ValueError("provenance run_order must contain complete profile pairs")
    for index in range(0, len(run_order), 2):
        first_profile, first_class = run_order[index].split(":", maxsplit=1)
        second_profile, second_class = run_order[index + 1].split(":", maxsplit=1)
        if first_class != second_class or {first_profile, second_profile} != PROFILES:
            raise ValueError("provenance run_order must keep each profile pair adjacent")
        expected_first = "efficient" if (index // 2) % 2 == 0 else "deep"
        if first_profile != expected_first:
            raise ValueError("provenance run_order must alternate the first profile in each pair")
    if run_order != _deterministic_run_order(pairing_seed):
        raise ValueError("provenance run_order must match pairing_seed")
    return run_order


def _parse_provenance(payload: object, results: Sequence[TaskResult]) -> BenchmarkProvenance:
    if not isinstance(payload, dict) or frozenset(payload) != PROVENANCE_FIELDS:
        raise ValueError("Input requires an exact privacy-safe provenance manifest")
    revision = payload["repository_revision"]
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("provenance repository_revision must be a full lowercase Git revision")
    if payload["working_tree_clean"] is not True:
        raise ValueError("provenance must assert a clean working tree")
    version = payload["benchmark_version"]
    if version != BENCHMARK_VERSION:
        raise ValueError(f"provenance benchmark_version must be {BENCHMARK_VERSION!r}")
    for field in ("fixture_sha256", "acceptance_sha256"):
        value = payload[field]
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
            raise ValueError(f"provenance {field} must be a SHA-256 digest")
    seed = payload["pairing_seed"]
    if not isinstance(seed, int) or isinstance(seed, bool) or seed < 0:
        raise ValueError("provenance pairing_seed must be a non-negative integer")
    return BenchmarkProvenance(
        repository_revision=revision,
        working_tree_clean=True,
        benchmark_version=version,
        fixture_sha256=payload["fixture_sha256"],
        acceptance_sha256=payload["acceptance_sha256"],
        pairing_seed=seed,
        run_order=_validate_run_order(payload["run_order"], results, seed),
    )


def load_benchmark(path: Path) -> tuple[BenchmarkProvenance, list[TaskResult]]:
    """Load a provenance-validated aggregate benchmark without task content."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ValueError(f"Unable to read input file: {path}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"Input is not valid JSON: {path}") from error
    if not isinstance(payload, dict) or frozenset(payload) != {"provenance", "results"}:
        raise ValueError("Input must contain only provenance and results")
    raw_results = payload["results"]
    if not isinstance(raw_results, list):
        raise ValueError("results must be a list")
    results = [_parse_result(result) for result in raw_results]
    for result in results:
        _validate_task_result(result)
    return _parse_provenance(payload["provenance"], results), results


def load_results(path: Path) -> list[TaskResult]:
    """Load and validate an aggregate-only JSON benchmark file."""
    _, results = load_benchmark(path)
    return results


def _safe_output_path(path: Path) -> Path:
    resolved = path.resolve()
    if resolved.is_relative_to(REPO_ROOT):
        raise ValueError("--output must be outside the repository")
    return resolved


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Aggregate-only input JSON")
    parser.add_argument("--output", type=Path, required=True, help="Comparison JSON output")
    return parser.parse_args()


def main() -> int:
    """Run the comparison CLI."""
    arguments = _parse_args()
    try:
        provenance, results = load_benchmark(arguments.input)
        comparison = compare_profiles(results)
        output = {**asdict(comparison), "provenance": asdict(provenance)}
        _safe_output_path(arguments.output).write_text(
            json.dumps(output, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError) as error:
        LOGGER.error("Profile comparison failed: %s", error)
        return 2
    LOGGER.info("Wrote aggregate profile comparison to %s", arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
