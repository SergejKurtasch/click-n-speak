from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from analyze_swift_soak import delay_after_stop_ms, main, parse_runtime_events, summarize  # noqa: E402
from compare_swift_parity_metrics import evaluate  # noqa: E402


@pytest.mark.parametrize("defect", ["failed", "incomplete", "legacy_snapshot", "none"])
def test_main_gate_rejects_partial_failure_and_unknown_run(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    defect: str,
) -> None:
    events: list[dict[str, object]] = []
    for session in range(100):
        common = {"run_id": "valid-run", "session_id": session}
        events.extend(
            [
                {**common, "event": "session_start", "monotonic": session * 300.0},
                {
                    **common,
                    "event": "chunk_processed",
                    "chunk_index": 0,
                    "outcome": "no_speech",
                    "monotonic": session * 300.0 + 1,
                },
                {**common, "event": "session_end", "reason": "no_speech", "monotonic": session * 300.0 + 2},
            ]
        )
    if defect == "failed":
        events[1]["outcome"] = "failed"
    elif defect == "incomplete":
        events.insert(2, {"event": "session_incomplete", "run_id": "valid-run", "session_id": 0})
    elif defect == "legacy_snapshot":
        events.append(
            {"event": "process_snapshot", "monotonic": 100_000.0, "parent_rss_mb": 100.0, "completed_sessions": 100}
        )
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
            "is_final": False,
            "queue_wait_ms": 100.0,
            "duration_ms": 500.0,
            "request_ms": 500.0,
            "outcome": "success",
            "monotonic": 102.0,
            "wall_clock": 1_002.0,
        },
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 1,
            "is_final": True,
            "queue_wait_ms": 150.0,
            "duration_ms": 550.0,
            "request_ms": 550.0,
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
            "editor_backend": "local",
            "editor_latency_ms": 100.0,
            "outcome": "ok",
            "monotonic": 108.0,
            "wall_clock": 1_008.0,
        },
        {
            "event": "session_stop",
            "run_id": "run-a",
            "session_id": 1,
            "monotonic": 107.0,
            "wall_clock": 1_007.0,
        },
        {
            "event": "session_end",
            "run_id": "run-a",
            "session_id": 1,
            "reason": "worker_finished",
            "monotonic": 110.0,
            "wall_clock": 1_010.0,
        },
        {
            "event": "session_end",
            "run_id": "run-a",
            "session_id": 1,
            "reason": "confirm",
            "stop_to_enter_ms": 3000.0,
            "monotonic": 110.1,
            "wall_clock": 1_010.1,
        },
        {
            "event": "first_preview_presented",
            "run_id": "run-a",
            "session_id": 1,
            "monotonic": 107.5,
        },
        {
            "event": "draft_preview_presented",
            "run_id": "run-a",
            "session_id": 1,
            "monotonic": 107.6,
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
            "editor_backend": "gemini",
            "editor_latency_ms": 10_000.0,
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
        {"event": "editor_refine", "editor_backend": "local", "editor_latency_ms": 100.0, "outcome": "ok"},
        {"event": "editor_refine", "editor_backend": "gemini", "editor_latency_ms": 10_000.0, "outcome": "ok"},
    ]

    assert summarize(events)["local_editor_p95_seconds"] == 0.1


def test_no_local_editor_events_omit_local_latency() -> None:
    events = [
        {"event": "editor_refine", "editor_backend": "gemini", "editor_latency_ms": 10_000.0},
    ]

    assert summarize(events)["local_editor_p95_seconds"] is None


def test_local_editor_latency_excludes_skips_and_reports_outcomes() -> None:
    events = [
        {
            "event": "editor_refine",
            "editor_backend": "local",
            "editor_latency_ms": 10.0,
            "outcome": "skipped",
        },
        {
            "event": "editor_refine",
            "editor_backend": "local",
            "editor_latency_ms": 2_000.0,
            "outcome": "ok",
        },
        {
            "event": "editor_refine",
            "editor_backend": "local",
            "editor_latency_ms": 500.0,
            "outcome": "unchanged",
        },
    ]

    result = summarize(events)

    assert result["local_editor_p95_seconds"] == 2.0
    assert result["local_editor_outcome_counts"] == {
        "ok": 1,
        "skipped": 1,
        "unchanged": 1,
    }


def test_duration_sums_runs_without_mixing_monotonic_epochs(
    mixed_run_events: list[dict[str, object]],
) -> None:
    result = summarize(mixed_run_events)

    assert result["duration_hours"] == pytest.approx(15.1 / 3_600.0)
    assert result["wall_clock_start"] == 1_000.0
    assert result["wall_clock_end"] == 2_005.0


def test_new_preview_and_enter_metrics(
    mixed_run_events: list[dict[str, object]],
) -> None:
    result = summarize(mixed_run_events)

    assert result["stop_to_first_preview_p50_seconds"] == 0.5
    assert result["stop_to_preview_p50_seconds"] == pytest.approx(0.6)
    assert result["stop_to_enter_p50_seconds"] == pytest.approx(3.1)
    assert result["chunk_queue_wait_p50_seconds"] == 0.1
    assert result["chunk_queue_wait_p95_seconds"] == 0.15
    assert result["stt_request_p50_seconds"] == 0.5
    assert result["stt_request_p95_seconds"] == 0.55


def test_delay_after_stop_distinguishes_missing_from_already_visible() -> None:
    assert delay_after_stop_ms(10.0, 9.0) == 0.0
    assert delay_after_stop_ms(10.0, 12.5) == 2_500.0
    assert delay_after_stop_ms(10.0, None) is None
    assert delay_after_stop_ms(None, 12.5) is None


def test_preview_and_enter_metrics_correlate_by_run_and_session() -> None:
    events = [
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 10.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 9.0},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 14.0},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 17.0},
        {"event": "session_stop", "run_id": "run-b", "session_id": 1, "monotonic": 100.0},
        {"event": "first_preview_presented", "run_id": "run-b", "session_id": 1, "monotonic": 102.0},
        {"event": "draft_preview_presented", "run_id": "run-b", "session_id": 1, "monotonic": 103.0},
        {"event": "session_end", "run_id": "run-b", "session_id": 1, "reason": "confirm", "monotonic": 104.0},
    ]

    result = summarize(events)

    assert result["stop_to_first_preview_p50_seconds"] == 0.0
    assert result["stop_to_first_preview_p95_seconds"] == 2.0
    assert result["stop_to_preview_p50_seconds"] == 3.0
    assert result["stop_to_preview_p95_seconds"] == 4.0
    assert result["stop_to_enter_p50_seconds"] == 4.0
    assert result["stop_to_enter_p95_seconds"] == 7.0
    assert result["incomplete_first_preview_count"] == 0
    assert result["incomplete_draft_preview_count"] == 0
    assert result["incomplete_enter_count"] == 0


def test_preview_metrics_report_missing_measurements_for_empty_and_incomplete_sessions() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "monotonic": 1.0},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 2.0},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "no_speech", "monotonic": 3.0},
        {"event": "session_start", "run_id": "run-a", "session_id": 2, "monotonic": 10.0},
        {"event": "session_stop", "run_id": "run-a", "session_id": 2, "monotonic": 11.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 2},
        {
            "event": "draft_preview_presented",
            "run_id": "run-a",
            "session_id": 2,
            "monotonic": 12.0,
            "append_mode": True,
        },
        {"event": "first_preview_presented", "run_id": "run-b", "session_id": 2, "monotonic": 13.0},
    ]

    result = summarize(events)

    assert result["stop_to_first_preview_p50_seconds"] is None
    assert result["stop_to_preview_p50_seconds"] == 1.0
    assert result["stop_to_enter_p50_seconds"] is None
    assert result["incomplete_first_preview_count"] == 3
    assert result["incomplete_draft_preview_count"] == 1
    assert result["incomplete_enter_count"] == 0


def test_timing_event_integrity_requires_one_stop_and_each_preview_for_confirmation() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 10.0},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 10.1},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 11.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 11.1},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 0, "outcome": "success"},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 12.0},
        {"event": "session_start", "run_id": "run-a", "session_id": 2},
        {"event": "session_stop", "run_id": "run-a", "session_id": 2, "monotonic": 20.0},
        {"event": "session_end", "run_id": "run-a", "session_id": 2, "reason": "no_speech"},
    ]

    result = summarize(events)

    assert result["missing_draft_preview_count"] == 1
    assert result["duplicate_session_stop_count"] == 1
    assert result["duplicate_first_preview_count"] == 1
    assert result["timing_event_integrity_error_count"] == 3


def test_successful_speech_then_no_speech_remains_timing_applicable() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 10.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 11.0},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 0, "outcome": "success"},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 1, "outcome": "no_speech"},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 12.0},
    ]

    result = summarize(events)

    assert result["missing_draft_preview_count"] == 1
    assert result["timing_event_integrity_error_count"] == 1


def test_timing_event_integrity_rejects_missing_and_nonfinite_timestamps() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": float("nan")},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": float("inf")},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 0, "outcome": "success"},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 12.0},
    ]

    result = summarize(events)

    assert result["invalid_session_stop_timestamp_count"] == 1
    assert result["invalid_first_preview_timestamp_count"] == 1
    assert result["invalid_draft_preview_timestamp_count"] == 1
    assert result["timing_event_integrity_error_count"] == 3


def test_timing_event_integrity_requires_one_finite_confirm_end() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 10.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 11.0},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 12.0},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 0, "outcome": "success"},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm"},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 13.0},
    ]

    result = summarize(events)

    assert result["duplicate_confirm_end_count"] == 1
    assert result["invalid_confirm_end_timestamp_count"] == 1
    assert result["timing_event_integrity_error_count"] == 2


def test_timing_event_integrity_rejects_final_preview_and_confirm_before_stop() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 10.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 9.0},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 9.0},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 0, "outcome": "success"},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 9.0},
    ]

    result = summarize(events)

    assert result["draft_preview_before_stop_count"] == 1
    assert result["confirm_end_before_stop_count"] == 1
    assert result["timing_event_integrity_error_count"] == 2
    assert result["stop_to_first_preview_p50_seconds"] == 0.0
    assert result["stop_to_preview_p50_seconds"] is None
    assert result["stop_to_enter_p50_seconds"] is None


@pytest.mark.parametrize("defect", ["missing_stop", "duplicate_first", "missing_draft"])
def test_main_gate_rejects_incomplete_timing_for_successful_confirmation(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    defect: str,
) -> None:
    events: list[dict[str, object]] = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "monotonic": 1.0},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 2.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 3.0},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 4.0},
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 0,
            "outcome": "success",
            "sample_count": 16_000,
            "stt_model": "whisper-test",
        },
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 5.0},
    ]
    if defect == "missing_stop":
        events.pop(1)
    elif defect == "duplicate_first":
        events.insert(3, dict(events[2]))
    elif defect == "missing_draft":
        events.pop(3)

    log_path = tmp_path / "runtime.log"
    output_path = tmp_path / "soak.json"
    log_path.write_text("".join(f"runtime_event {json.dumps(event)}\n" for event in events))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "soak",
            "--log",
            str(log_path),
            "--output",
            str(output_path),
            "--minimum-hours",
            "0",
            "--minimum-sessions",
            "1",
        ],
    )

    assert main() == 1
    document = json.loads(output_path.read_text(encoding="utf-8"))
    assert "timing_event_integrity" in document["failures"]


@pytest.mark.parametrize("defect", ["orphan_draft", "non_confirmed_duplicate_stop"])
def test_main_gate_rejects_orphan_and_non_confirmed_duplicate_timing_events(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    defect: str,
) -> None:
    events: list[dict[str, object]] = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "monotonic": 1.0},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 2.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 3.0},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 4.0},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 0, "outcome": "success"},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 5.0},
    ]
    if defect == "orphan_draft":
        events.append({"event": "draft_preview_presented", "run_id": "run-a", "session_id": 77, "monotonic": 6.0})
    else:
        events.extend(
            [
                {"event": "session_start", "run_id": "run-a", "session_id": 2, "monotonic": 6.0},
                {"event": "session_stop", "run_id": "run-a", "session_id": 2, "monotonic": 7.0},
                {"event": "session_stop", "run_id": "run-a", "session_id": 2, "monotonic": 8.0},
                {"event": "session_end", "run_id": "run-a", "session_id": 2, "reason": "cancel", "monotonic": 9.0},
            ]
        )

    log_path = tmp_path / "runtime.log"
    output_path = tmp_path / "soak.json"
    log_path.write_text("".join(f"runtime_event {json.dumps(event)}\n" for event in events))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "soak",
            "--log",
            str(log_path),
            "--output",
            str(output_path),
            "--minimum-hours",
            "0",
            "--minimum-sessions",
            "1",
        ],
    )

    assert main() == 1
    document = json.loads(output_path.read_text(encoding="utf-8"))
    assert "timing_event_integrity" in document["failures"]


def test_latency_breakdowns_use_model_append_mode_and_sample_count() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "append_mode": False},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 10.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 11.0},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 12.0},
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 0,
            "outcome": "success",
            "sample_count": 8_000,
            "stt_model": "whisper-a",
        },
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 13.0},
        {"event": "session_start", "run_id": "run-a", "session_id": 2, "append_mode": True},
        {"event": "session_stop", "run_id": "run-a", "session_id": 2, "monotonic": 20.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 2, "monotonic": 20.0},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 2, "monotonic": 22.0},
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 2,
            "chunk_index": 0,
            "outcome": "success",
            "sample_count": 40_000,
            "stt_model": "whisper-b",
        },
        {"event": "session_end", "run_id": "run-a", "session_id": 2, "reason": "confirm", "monotonic": 24.0},
    ]

    breakdowns = summarize(events)["latency_breakdowns"]

    assert breakdowns["by_stt_model"]["whisper-a"] == {
        "count": 1,
        "n": 1,
        "stop_to_first_preview_p50_seconds": 1.0,
        "stop_to_first_preview_p95_seconds": 1.0,
        "stop_to_preview_p50_seconds": 2.0,
        "stop_to_preview_p95_seconds": 2.0,
        "stop_to_enter_p50_seconds": 3.0,
        "stop_to_enter_p95_seconds": 3.0,
    }
    assert breakdowns["by_append_mode"]["append"] == {
        "count": 1,
        "n": 1,
        "stop_to_first_preview_p50_seconds": 0.0,
        "stop_to_first_preview_p95_seconds": 0.0,
        "stop_to_preview_p50_seconds": 2.0,
        "stop_to_preview_p95_seconds": 2.0,
        "stop_to_enter_p50_seconds": 4.0,
        "stop_to_enter_p95_seconds": 4.0,
    }
    assert breakdowns["by_sample_count_bucket"]["short_<=16000"]["count"] == 1
    assert breakdowns["by_sample_count_bucket"]["medium_<=64000"]["stop_to_enter_p50_seconds"] == 4.0


def test_latency_breakdowns_fail_closed_for_partial_chunk_metadata() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "append_mode": False},
        {"event": "session_stop", "run_id": "run-a", "session_id": 1, "monotonic": 10.0},
        {"event": "first_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 11.0},
        {"event": "draft_preview_presented", "run_id": "run-a", "session_id": 1, "monotonic": 12.0},
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 0,
            "outcome": "success",
            "sample_count": 8_000,
            "stt_model": "whisper-a",
        },
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 1, "outcome": "success"},
        {"event": "session_end", "run_id": "run-a", "session_id": 1, "reason": "confirm", "monotonic": 13.0},
    ]

    breakdowns = summarize(events)["latency_breakdowns"]

    assert "whisper-a" not in breakdowns["by_stt_model"]
    assert breakdowns["by_stt_model"]["unknown"]["count"] == 1
    assert "short_<=16000" not in breakdowns["by_sample_count_bucket"]
    assert breakdowns["by_sample_count_bucket"]["unknown"]["count"] == 1


def test_chunk_latency_breakdowns_cover_queue_request_model_scenario_and_workload() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "append_mode": False},
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 1,
            "chunk_index": 0,
            "stt_model": "whisper-a",
            "sample_count": 8_000,
            "queue_wait_ms": 10.0,
            "request_ms": 100.0,
        },
        {"event": "session_start", "run_id": "run-a", "session_id": 2, "append_mode": True},
        {
            "event": "chunk_processed",
            "run_id": "run-a",
            "session_id": 2,
            "chunk_index": 0,
            "stt_model": "whisper-b",
            "sample_count": 48_000,
            "queue_wait_ms": 30.0,
            "request_ms": 300.0,
        },
    ]

    breakdowns = summarize(events)["latency_breakdowns"]

    assert breakdowns["chunk_queue_wait"]["by_stt_model"]["whisper-a"] == {
        "n": 1,
        "p50_seconds": 0.01,
        "p95_seconds": 0.01,
    }
    assert breakdowns["stt_request"]["by_append_mode"]["append"] == {
        "n": 1,
        "p50_seconds": 0.3,
        "p95_seconds": 0.3,
    }
    assert breakdowns["chunk_queue_wait"]["by_sample_count_bucket"]["medium_<=64000"]["p95_seconds"] == 0.03


def test_local_editor_breakdowns_keep_unknown_workload_and_exclude_skips() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "append_mode": True},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 0, "sample_count": 8_000},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 1, "sample_count": 10_000},
        {
            "event": "editor_refine",
            "run_id": "run-a",
            "session_id": 1,
            "editor_backend": "local",
            "editor_model": "qwen",
            "editor_latency_ms": 10.0,
            "outcome": "skipped",
        },
        {
            "event": "editor_refine",
            "run_id": "run-a",
            "session_id": 1,
            "editor_backend": "local",
            "editor_model": "qwen",
            "editor_latency_ms": 500.0,
            "outcome": "unchanged",
        },
        {"event": "session_start", "run_id": "run-a", "session_id": 2, "append_mode": False},
        {
            "event": "editor_refine",
            "run_id": "run-a",
            "session_id": 2,
            "editor_backend": "local",
            "editor_model": "qwen",
            "editor_latency_ms": 1_000.0,
            "outcome": "ok",
        },
    ]

    breakdowns = summarize(events)["latency_breakdowns"]["local_editor_latency"]

    assert breakdowns["by_editor_model"]["qwen"] == {
        "n": 2,
        "p50_seconds": 0.5,
        "p95_seconds": 1.0,
    }
    assert breakdowns["by_append_mode"]["append"]["n"] == 1
    assert breakdowns["by_workload_bucket"]["medium_<=64000"]["p95_seconds"] == 0.5
    assert breakdowns["by_workload_bucket"]["unknown_editor_workload"]["p95_seconds"] == 1.0


def test_local_editor_breakdowns_fail_closed_for_partial_sample_metadata() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "append_mode": False},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 0, "sample_count": 8_000},
        {"event": "chunk_processed", "run_id": "run-a", "session_id": 1, "chunk_index": 1},
        {
            "event": "editor_refine",
            "run_id": "run-a",
            "session_id": 1,
            "editor_backend": "local",
            "editor_model": "qwen",
            "editor_latency_ms": 500.0,
            "outcome": "ok",
        },
    ]

    breakdowns = summarize(events)["latency_breakdowns"]["local_editor_latency"]

    assert "short_<=16000" not in breakdowns["by_workload_bucket"]
    assert breakdowns["by_workload_bucket"]["unknown_editor_workload"]["n"] == 1


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
