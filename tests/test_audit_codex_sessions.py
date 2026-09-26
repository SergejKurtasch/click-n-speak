from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path

import pytest

from scripts.audit_codex_sessions import compare_14_day_reports, summarize_rollouts

START = datetime(2026, 9, 10, tzinfo=UTC)
END = datetime(2026, 9, 12, tzinfo=UTC)


@pytest.fixture
def session_fixture() -> Path:
    return Path(__file__).parent / "fixtures" / "codex_sessions" / "privacy_boundary.jsonl"


def test_summary_omits_content_fields(session_fixture: Path) -> None:
    """A report must not retain text from messages or command arguments."""
    summary = summarize_rollouts([session_fixture], START, END)
    payload = json.dumps(asdict(summary), sort_keys=True)

    assert "private transcript" not in payload
    assert "git commit -m" not in payload
    assert summary.compactions == 1
    assert summary.approval_events == 2


def test_summary_counts_allowed_metadata_only(session_fixture: Path) -> None:
    """Allowed session metadata is aggregated inside the requested time range."""
    summary = summarize_rollouts([session_fixture], START, END)

    assert summary.logical_sessions == 1
    assert summary.root_turns == 1
    assert summary.subagent_turns == 1
    assert summary.guardian_turns == 1
    assert summary.input_tokens == 400
    assert summary.missing_command_events == 1
    assert summary.model_effort_distribution == {
        "gpt-5.6-luna": {"medium": 2},
        "gpt-6-astra": {"high": 1},
    }
    assert summary.window_start == "2026-09-10T00:00:00Z"
    assert summary.window_end == "2026-09-12T00:00:00Z"


def test_summary_does_not_replace_a_total_with_last_turn_tokens(tmp_path: Path) -> None:
    """A last-turn value must not replace the cumulative total-token counter."""
    rollout = tmp_path / "legacy-rollout.jsonl"
    rollout.write_text(
        "\n".join(
            (
                '{"timestamp":"2026-09-11T09:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250},"last_token_usage":{"input_tokens":999}}}}',
                '{"timestamp":"2026-09-11T09:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":321}}}}',
            )
        ),
        encoding="utf-8",
    )

    summary = summarize_rollouts([rollout], START, END)

    assert summary.input_tokens == 250


def test_summary_uses_last_turn_tokens_for_a_legacy_rollout(tmp_path: Path) -> None:
    """Older rollout files without total_token_usage retain a safe fallback."""
    rollout = tmp_path / "legacy-rollout.jsonl"
    rollout.write_text(
        "\n".join(
            (
                '{"timestamp":"2026-09-11T09:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":250}}}}',
                '{"timestamp":"2026-09-11T09:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":321}}}}',
            )
        ),
        encoding="utf-8",
    )

    summary = summarize_rollouts([rollout], START, END)

    assert summary.input_tokens == 321


@pytest.mark.parametrize("invalid_end", [START, START.replace(day=9)])
def test_summary_rejects_a_non_positive_report_window(session_fixture: Path, invalid_end: datetime) -> None:
    """An empty or reversed public window must not silently emit a report."""
    with pytest.raises(ValueError, match="end.*after start"):
        summarize_rollouts([session_fixture], START, invalid_end)


def test_summary_ignores_records_outside_requested_time_range(session_fixture: Path) -> None:
    """Records outside the selected report window must not change aggregates."""
    summary = summarize_rollouts([session_fixture], START, END)

    assert summary.root_turns == 1


def test_distribution_counts_turn_context_records_not_task_starts(session_fixture: Path) -> None:
    """Counting task-start events would misstate the observed model selection."""
    summary = summarize_rollouts([session_fixture], START, END)

    assert summary.model_effort_distribution["gpt-5.6-luna"]["medium"] == 2


def test_compare_14_day_reports_requires_non_overlapping_fourteen_day_windows(
    session_fixture: Path,
) -> None:
    """Comparing arbitrary report spans would make trend percentages misleading."""
    baseline = asdict(summarize_rollouts([session_fixture], START, END))
    comparison = dict(baseline)
    comparison["window_start"] = "2026-09-12T00:00:00Z"
    comparison["window_end"] = "2026-09-26T00:00:00Z"

    with pytest.raises(ValueError, match="14-day"):
        compare_14_day_reports(baseline, comparison)


def test_compare_14_day_reports_reports_aggregate_changes_only() -> None:
    """A report comparison must expose derived counts, never session bodies."""
    baseline = {
        "window_start": "2026-09-01T00:00:00Z",
        "window_end": "2026-09-15T00:00:00Z",
        "logical_sessions": 2,
        "root_turns": 10,
        "subagent_turns": 1,
        "guardian_turns": 0,
        "compactions": 10,
        "approval_events": 10,
        "input_tokens": 1000,
        "missing_command_events": 2,
        "model_effort_distribution": {},
    }
    comparison = {
        **baseline,
        "window_start": "2026-09-16T00:00:00Z",
        "window_end": "2026-09-30T00:00:00Z",
        "root_turns": 10,
        "compactions": 7,
        "approval_events": 3,
        "input_tokens": 500,
        "missing_command_events": 0,
    }

    report = compare_14_day_reports(baseline, comparison)

    assert report["approval_event_reduction_percent"] == 70.0
    assert report["input_token_reduction_percent"] == 50.0
    assert report["comparison_missing_command_events"] == 0
    assert "private transcript" not in json.dumps(report, sort_keys=True)


def test_cli_rejects_a_repository_output_path(tmp_path: Path) -> None:
    """Writing telemetry into the checkout could accidentally commit it."""
    repository_output = Path.cwd() / "audit-report.json"

    completed = subprocess.run(
        [
            sys.executable,
            "scripts/audit_codex_sessions.py",
            "--sessions-root",
            str(tmp_path),
            "--output",
            str(repository_output),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 2
    assert not repository_output.exists()
