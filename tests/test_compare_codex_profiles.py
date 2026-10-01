from __future__ import annotations

import json
import math
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

import pytest

from scripts.compare_codex_profiles import (
    TaskResult,
    compare_profiles,
    load_results,
)

PROVENANCE = {
    "repository_revision": "a" * 40,
    "working_tree_clean": True,
    "benchmark_version": "1",
    "fixture_sha256": "b" * 64,
    "acceptance_sha256": "c" * 64,
    "pairing_seed": 20260924,
    "run_order": [
        "efficient:regression_review",
        "deep:regression_review",
        "deep:small_bug_diagnosis",
        "efficient:small_bug_diagnosis",
        "efficient:documentation_update",
        "deep:documentation_update",
        "deep:multi_file_refactor_plan",
        "efficient:multi_file_refactor_plan",
        "efficient:test_failure_triage",
        "deep:test_failure_triage",
        "deep:release_script_review",
        "efficient:release_script_review",
        "efficient:python_parity_check",
        "deep:python_parity_check",
        "deep:focused_unit_fix",
        "efficient:focused_unit_fix",
        "efficient:swift_concurrency_review",
        "deep:swift_concurrency_review",
        "deep:config_migration",
        "efficient:config_migration",
    ],
}


def _results(
    *,
    efficient_clean: int = 10,
    deep_clean: int = 10,
    efficient_rework: int = 0,
    deep_rework: int = 0,
    efficient_tokens: int = 100,
    deep_tokens: int = 200,
) -> list[TaskResult]:
    """Build ten aggregate-only paired results with hand-checked metrics."""
    classes = [
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
    ]
    efficient = [
        TaskResult(
            profile="efficient",
            task_class=task_class,
            completion=index < efficient_clean,
            user_corrections=efficient_rework if index == 0 else 0,
            regressions=0,
            wall_time_seconds=30,
            input_tokens=efficient_tokens // 2,
            output_tokens=efficient_tokens // 2,
        )
        for index, task_class in enumerate(classes)
    ]
    deep = [
        TaskResult(
            profile="deep",
            task_class=task_class,
            completion=index < deep_clean,
            user_corrections=deep_rework if index == 0 else 0,
            regressions=0,
            wall_time_seconds=10,
            input_tokens=deep_tokens // 2,
            output_tokens=deep_tokens // 2,
        )
        for index, task_class in enumerate(classes)
    ]
    return efficient + deep


def test_efficient_profile_requires_nine_clean_completions() -> None:
    """A lowered completion threshold would wrongly promote eight clean tasks."""
    comparison = compare_profiles(_results(efficient_clean=8, deep_clean=10))

    assert comparison.promote_efficient is False


def test_efficient_profile_can_win_without_more_rework() -> None:
    """Matching rework with nine clean tasks and lower tokens permits promotion."""
    comparison = compare_profiles(_results(efficient_clean=9, deep_clean=9, efficient_rework=1, deep_rework=1))

    assert comparison.promote_efficient is True


def test_faster_wall_time_cannot_replace_lower_token_requirement() -> None:
    """Treating wall time as a sufficient criterion would promote an expensive profile."""
    comparison = compare_profiles(_results(efficient_tokens=300, deep_tokens=200))

    assert comparison.promote_efficient is False
    assert comparison.efficient_median_total_tokens == 300
    assert comparison.deep_median_total_tokens == 200


def test_more_regressions_prevents_promotion() -> None:
    """Ignoring regressions would promote a profile that caused more breakage."""
    results = _results()
    results[0] = TaskResult(
        profile="efficient",
        task_class="small_bug_diagnosis",
        completion=True,
        user_corrections=0,
        regressions=1,
        wall_time_seconds=30,
        input_tokens=50,
        output_tokens=50,
    )

    assert compare_profiles(results).promote_efficient is False


def test_non_representative_task_classes_are_rejected() -> None:
    """Changing the fixed benchmark set would invalidate a paired comparison."""
    results = _results()
    results[0] = TaskResult(
        profile="efficient",
        task_class="unapproved_class",
        completion=True,
        user_corrections=0,
        regressions=0,
        wall_time_seconds=30,
        input_tokens=50,
        output_tokens=50,
    )

    with pytest.raises(ValueError, match="representative"):
        compare_profiles(results)


@pytest.mark.parametrize("invalid_wall_time", [math.nan, math.inf])
def test_non_finite_wall_time_is_rejected(invalid_wall_time: float) -> None:
    """Serializing non-finite timing values would produce invalid JSON output."""
    results = _results()
    results[0] = TaskResult(
        profile="efficient",
        task_class="small_bug_diagnosis",
        completion=True,
        user_corrections=0,
        regressions=0,
        wall_time_seconds=invalid_wall_time,
        input_tokens=50,
        output_tokens=50,
    )

    with pytest.raises(ValueError, match="finite"):
        compare_profiles(results)


def test_loader_rejects_task_text_and_requires_aggregate_fields(tmp_path: Path) -> None:
    """Accepting task content would violate the aggregate-only benchmark boundary."""
    path = tmp_path / "results.json"
    path.write_text(
        json.dumps(
            {
                "provenance": PROVENANCE,
                "results": [
                    {
                        **asdict(_results()[0]),
                        "task_text": "sensitive benchmark prompt",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="not permitted"):
        load_results(path)


def test_cli_writes_aggregate_comparison_without_task_content(tmp_path: Path) -> None:
    """The command-line report retains decisions and metrics, never benchmark text."""
    source = tmp_path / "results.json"
    target = tmp_path / "comparison.json"
    source.write_text(
        json.dumps({"provenance": PROVENANCE, "results": [asdict(result) for result in _results()]}),
        encoding="utf-8",
    )

    completed = subprocess.run(
        [
            sys.executable,
            "scripts/compare_codex_profiles.py",
            "--input",
            str(source),
            "--output",
            str(target),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr
    report = target.read_text(encoding="utf-8")
    assert json.loads(report)["promote_efficient"] is True
    assert "task_text" not in report


def test_loader_requires_a_clean_text_free_provenance_manifest(tmp_path: Path) -> None:
    """A benchmark without reproducibility evidence must not be compared."""
    path = tmp_path / "results.json"
    path.write_text(json.dumps({"results": [asdict(result) for result in _results()]}), encoding="utf-8")

    with pytest.raises(ValueError, match="provenance"):
        load_results(path)


def test_loader_rejects_a_dirty_or_content_bearing_provenance_manifest(tmp_path: Path) -> None:
    """A dirty checkout or task text invalidates an otherwise aggregate benchmark."""
    path = tmp_path / "results.json"
    dirty_provenance = {**PROVENANCE, "working_tree_clean": False}
    path.write_text(
        json.dumps({"provenance": dirty_provenance, "results": [asdict(result) for result in _results()]}),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="clean"):
        load_results(path)


def test_loader_rejects_a_provenance_version_with_task_text(tmp_path: Path) -> None:
    """The fixed benchmark version cannot become a channel for task content."""
    path = tmp_path / "results.json"
    path.write_text(
        json.dumps(
            {
                "provenance": {**PROVENANCE, "benchmark_version": "private task text"},
                "results": [asdict(result) for result in _results()],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="benchmark_version"):
        load_results(path)


def test_loader_rejects_a_run_order_that_does_not_match_its_seed(tmp_path: Path) -> None:
    """A recorded seed must prove the shuffled paired execution order."""
    path = tmp_path / "results.json"
    path.write_text(
        json.dumps(
            {
                "provenance": {**PROVENANCE, "pairing_seed": 7},
                "results": [asdict(result) for result in _results()],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="pairing_seed"):
        load_results(path)


def test_loader_rejects_an_unpaired_provenance_run_order(tmp_path: Path) -> None:
    """An incomplete pair must be a validation error, not an indexing failure."""
    path = tmp_path / "results.json"
    single_result = _results()[0]
    path.write_text(
        json.dumps(
            {
                "provenance": {
                    **PROVENANCE,
                    "run_order": ["efficient:small_bug_diagnosis"],
                },
                "results": [asdict(single_result)],
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="pairs"):
        load_results(path)


def test_cli_rejects_a_repository_output_path(tmp_path: Path) -> None:
    """A comparison report must stay out of version-controlled project files."""
    source = tmp_path / "results.json"
    source.write_text(
        json.dumps({"provenance": PROVENANCE, "results": [asdict(result) for result in _results()]}),
        encoding="utf-8",
    )
    repository_output = Path.cwd() / "profile-comparison.json"

    completed = subprocess.run(
        [
            sys.executable,
            "scripts/compare_codex_profiles.py",
            "--input",
            str(source),
            "--output",
            str(repository_output),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 2
    assert not repository_output.exists()
