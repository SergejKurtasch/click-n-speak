from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from analyze_swift_soak import main, parse_runtime_events, summarize  # noqa: E402
from compare_swift_parity_metrics import evaluate  # noqa: E402


@pytest.mark.parametrize("defect", ["failed", "incomplete", "legacy_snapshot", "none"])
def test_main_gate_rejects_partial_failure_and_unknown_run(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, defect: str,
) -> None:
    events: list[dict[str, object]] = []
    for session in range(100):
        common = {"run_id": "valid-run", "session_id": session}
        events.extend([
            {**common, "event": "session_start", "monotonic": session * 300.0},
            {**common, "event": "chunk_processed", "chunk_index": 0,
             "outcome": "no_speech", "monotonic": session * 300.0 + 1},
            {**common, "event": "session_end", "reason": "no_speech",
             "monotonic": session * 300.0 + 2},
        ])
    if defect == "failed":
        events[1]["outcome"] = "failed"
    elif defect == "incomplete":
        events.insert(2, {"event": "session_incomplete", "run_id": "valid-run", "session_id": 0})
    elif defect == "legacy_snapshot":
        events.append({"event": "process_snapshot", "monotonic": 100_000.0,
                       "parent_rss_mb": 100.0, "completed_sessions": 100})
    log_path = tmp_path / "runtime.log"
    output = tmp_path / "output.json"
    log_path.write_text("".join(f"runtime_event {json.dumps(event)}\n" for event in events))
    monkeypatch.setattr(sys, "argv", ["soak", "--log", str(log_path), "--output", str(output)])
    assert main() == (0 if defect == "none" else 1)
    document = json.loads(output.read_text())
    assert document["status"] == ("passed" if defect == "none" else "failed")
    assert document["summary"]["duration_hours"] == pytest.approx(29_702 / 3600)


@pytest.fixture
def mixed_run_events() -> list[dict[str, object]]:
    return [
        {
            "event": "session_start",
            "run_id": "run-a",
            "session_id": 1,
            "monotonic": 100.0,
            "wall_clock": 1_000.0,
        },
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 0,
            "outcome": "success",
            "monotonic": 102.0,
            "wall_clock": 1_002.0,
        },
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 1,
            "outcome": "failed",
            "monotonic": 104.0,
            "wall_clock": 1_004.0,
        },
        {
            "event": "session_incomplete",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 1,
            "monotonic": 104.1,
            "wall_clock": 1_004.1,
        },
        {
            "event": "editor_refine",
            "run_id": "run-a",
            "session_id": 1,
            "backend": "local",
            "duration_ms": 100.0,
            "monotonic": 108.0,
            "wall_clock": 1_008.0,
        },
        {
            "event": "session_end",
            "run_id": "run-a",
            "session_id": 1,
            "reason": "confirm",
            "monotonic": 110.0,
            "wall_clock": 1_010.0,
        },
        {
            "event": "session_end",
            "run_id": "run-a",
            "session_id": 1,
            "reason": "confirm",
            "monotonic": 110.1,
            "wall_clock": 1_010.1,
        },
        {
            "event": "session_start",
            "run_id": "run-b",
            "session_id": 1,
            "monotonic": 2.0,
            "wall_clock": 2_000.0,
        },
        {
            "event": "chunk_processed",
            "run_id": "run-b",
            "session_id": 1,
            "chunk_index": 0,
            "outcome": "no_speech",
            "monotonic": 5.0,
            "wall_clock": 2_003.0,
        },
        {
            "event": "editor_refine",
            "run_id": "run-b",
            "session_id": 1,
            "backend": "gemini",
            "duration_ms": 10_000.0,
            "monotonic": 6.0,
            "wall_clock": 2_004.0,
        },
        {
            "event": "session_end",
            "run_id": "run-b",
            "session_id": 1,
            "reason": "no_speech",
            "monotonic": 7.0,
            "wall_clock": 2_005.0,
        },
    ]


def test_relaunch_sessions_are_distinct() -> None:
    events = [
        {
            "event": "session_start",
            "run_id": "run-a",
            "session_id": 1,
            "monotonic": 0.0,
        },
        {
            "event": "session_start",
            "run_id": "run-b",
            "session_id": 1,
            "monotonic": 10.0,
        },
    ]

    assert summarize(events)["session_count"] == 2


def test_local_editor_latency_excludes_cloud() -> None:
    events = [
        {"event": "editor_refine", "backend": "local", "duration_ms": 100.0},
        {"event": "editor_refine", "backend": "gemini", "duration_ms": 10_000.0},
    ]

    assert summarize(events)["local_editor_p95_seconds"] == 0.1


def test_no_local_editor_events_omit_local_latency() -> None:
    events = [
        {"event": "editor_refine", "backend": "gemini", "duration_ms": 10_000.0},
    ]

    assert summarize(events)["local_editor_p95_seconds"] is None


def test_duration_sums_runs_without_mixing_monotonic_epochs(
    mixed_run_events: list[dict[str, object]],
) -> None:
    result = summarize(mixed_run_events)

    assert result["duration_hours"] == pytest.approx(15.1 / 3_600.0)
    assert result["wall_clock_start"] == 1_000.0
    assert result["wall_clock_end"] == 2_005.0


def test_session_integrity_tracks_outcomes_failures_and_incomplete_sessions(
    mixed_run_events: list[dict[str, object]],
) -> None:
    result = summarize(mixed_run_events)

    assert result["session_count"] == 2
    assert result["session_outcome_count"] == 3
    assert result["duplicate_session_outcome_count"] == 1
    assert result["missing_session_outcome_count"] == 0
    assert result["incomplete_session_count"] == 1
    assert result["failed_chunk_count"] == 1
    assert result["no_speech_session_count"] == 1
    assert result["chunk_sequence_error_count"] == 0
    assert result["session_integrity_error_count"] == 3


def test_failed_chunk_and_incomplete_session_are_integrity_failures() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1},
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 0,
            "outcome": "failed",
        },
        {
            "event": "session_incomplete",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 0,
        },
        {"event": "session_end", "run_id": "run-a", "session_id": 1},
    ]

    result = summarize(events)

    assert result["failed_chunk_count"] == 1
    assert result["incomplete_session_count"] == 1
    assert result["session_integrity_error_count"] == 2


def test_missing_null_and_invalid_run_ids_are_identity_failures() -> None:
    events = [
        {"event": "session_start", "session_id": 1, "monotonic": 100_000.0},
        {"event": "session_end", "session_id": 1, "monotonic": 100_010.0},
        {"event": "session_start", "run_id": None, "session_id": 2, "monotonic": 1.0},
        {"event": "session_end", "run_id": None, "session_id": 2, "monotonic": 11.0},
        {"event": "session_start", "run_id": [], "session_id": 3, "monotonic": 1.0},
        {"event": "session_end", "run_id": [], "session_id": 3, "monotonic": 11.0},
    ]

    result = summarize(events)

    assert result["identity_error_count"] == 6
    assert result["duration_hours"] == 0.0


def test_chunk_sequence_detects_duplicates_and_gaps() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1},
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 0,
        },
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 2,
        },
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 2,
        },
        {"event": "session_end", "run_id": "run-a", "session_id": 1},
    ]

    result = summarize(events)

    assert result["chunk_sequence_error_count"] == 2
    assert result["session_integrity_error_count"] == 2


def test_rss_growth_compares_only_matching_workload_within_each_run() -> None:
    events = [
        {
            "event": "process_snapshot",
            "run_id": "run-a",
            "completed_sessions": 1,
            "parent_rss_mb": 100.0,
            "stt_backend": "local",
            "stt_model": "whisper",
            "ai_backend": "local",
            "ai_model": "qwen",
        },
        {
            "event": "process_snapshot",
            "run_id": "run-b",
            "completed_sessions": 1,
            "parent_rss_mb": 1_000.0,
            "stt_backend": "local",
            "stt_model": "whisper",
            "ai_backend": "local",
            "ai_model": "qwen",
        },
        {
            "event": "process_snapshot",
            "run_id": "run-a",
            "completed_sessions": 101,
            "parent_rss_mb": 150.0,
            "stt_backend": "local",
            "stt_model": "whisper",
            "ai_backend": "local",
            "ai_model": "qwen",
        },
        {
            "event": "process_snapshot",
            "run_id": "run-b",
            "completed_sessions": 101,
            "parent_rss_mb": 900.0,
            "stt_backend": "local",
            "stt_model": "whisper",
            "ai_backend": "local",
            "ai_model": "qwen",
        },
    ]

    result = summarize(events)

    assert result["peak_rss_mb"] == 1_000.0
    assert result["rss_growth_mb"] == 50.0


def _local_rss_snapshot(completed_sessions: int, parent_rss_mb: float) -> dict[str, object]:
    return {
        "event": "process_snapshot",
        "run_id": "run-a",
        "completed_sessions": completed_sessions,
        "parent_rss_mb": parent_rss_mb,
        "stt_backend": "local",
        "stt_model": "whisper",
        "ai_backend": "local",
        "ai_model": "qwen",
    }


def test_rss_growth_ignores_transient_spike_within_continuous_workload() -> None:
    events = [
        _local_rss_snapshot(
            completed_sessions,
            1_010.0 if completed_sessions == 2 else 1_000.0,
        )
        for completed_sessions in range(1, 102)
    ]

    result = summarize(events)

    assert result["peak_rss_mb"] == 1_010.0
    assert result["rss_growth_mb"] == 0.0


def test_rss_growth_tracks_sustained_continuous_workload_growth() -> None:
    events = [
        _local_rss_snapshot(
            completed_sessions,
            1_000.0 + ((completed_sessions - 1) * 0.5),
        )
        for completed_sessions in range(1, 102)
    ]

    result = summarize(events)

    assert result["peak_rss_mb"] == 1_050.0
    assert result["rss_growth_mb"] == 50.0


@pytest.mark.parametrize("middle_rss", [500.0, None])
def test_rss_growth_rejects_a_to_b_to_a_workload_intervals(middle_rss: float | None) -> None:
    events = [
        {
            "event": "process_snapshot",
            "run_id": "run-a",
            "completed_sessions": 1,
            "parent_rss_mb": 100.0,
            "stt_backend": "local",
            "stt_model": "whisper-a",
            "ai_backend": "local",
            "ai_model": "qwen",
        },
        {
            "event": "process_snapshot",
            "run_id": "run-a",
            "completed_sessions": 100,
            "parent_rss_mb": middle_rss,
            "stt_backend": "cloud",
            "stt_model": "cloud-b",
            "ai_backend": "none",
            "ai_model": "none",
        },
        {
            "event": "process_snapshot",
            "run_id": "run-a",
            "completed_sessions": 101,
            "parent_rss_mb": 110.0,
            "stt_backend": "local",
            "stt_model": "whisper-a",
            "ai_backend": "local",
            "ai_model": "qwen",
        },
    ]

    assert summarize(events)["rss_growth_mb"] is None


def test_runtime_owned_metrics_replace_imported_values_without_samples(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    log_path = tmp_path / "runtime.log"
    output_path = tmp_path / "soak.json"
    quality_path = tmp_path / "quality.json"
    log_path.write_text("", encoding="utf-8")
    quality_path.write_text(
        json.dumps(
            {
                "metrics": {
                    "local_editor_p95_seconds": 0.1,
                    "rss_growth_100_sessions_mb": 0.1,
                    "unrelated_quality_metric": 7,
                }
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "analyze_swift_soak.py",
            "--log",
            str(log_path),
            "--output",
            str(output_path),
            "--quality-metrics",
            str(quality_path),
        ],
    )

    assert main() == 1

    metrics = json.loads(output_path.read_text(encoding="utf-8"))["metrics"]
    assert metrics["local_editor_p95_seconds"] is None
    assert metrics["rss_growth_100_sessions_mb"] is None
    assert metrics["unrelated_quality_metric"] == 7


def test_callback_metric_is_labelled_as_session_maxima_distribution() -> None:
    events = [
        {
            "event": "audio_capture_stats",
            "run_id": "run-a",
            "session_id": 1,
            "maximum_callback_ms": 2.0,
            "overflow_samples": 0,
        },
        {
            "event": "audio_capture_stats",
            "run_id": "run-a",
            "session_id": 2,
            "maximum_callback_ms": 4.0,
            "overflow_samples": 0,
        },
    ]

    result = summarize(events)

    assert result["audio_callback_p95_ms"] == 4.0
    assert result["audio_callback_metric_basis"] == "session_maxima"


@pytest.mark.parametrize("field_name", ["key", "api_key"])
def test_nested_sensitive_telemetry_fields_are_rejected(
    tmp_path: Path,
    field_name: str,
) -> None:
    path = tmp_path / "runtime.log"
    payload = {"event": "bad", "payload": {field_name: "private"}}
    path.write_text(f"runtime_event {json.dumps(payload)}\n", encoding="utf-8")

    with pytest.raises(ValueError, match="Sensitive telemetry field name"):
        parse_runtime_events(path)


@pytest.mark.parametrize("status", ["failed", "skipped"])
def test_metric_comparison_rejects_nonpassing_soak_evidence(status: str) -> None:
    thresholds = {
        "thresholds": {
            "peak_rss_mb": {"direction": "maximum", "value": 2_200.0},
        }
    }
    candidate = {
        "status": status,
        "metrics": {"peak_rss_mb": 100.0},
    }

    _, failures = evaluate(candidate, thresholds)

    assert failures == ["soak_evidence"]
