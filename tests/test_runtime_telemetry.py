import json
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

import pytest

from scripts.analyze_runtime_log import load_events, summarize_events
from src.runtime_telemetry import emit_runtime_event


def test_runtime_event_is_json_and_contains_no_content() -> None:
    with patch("src.runtime_telemetry.log_info") as log_info:
        emit_runtime_event("transcribe_finished", session_id=4, chunk_index=2, char_count=18)

    message = log_info.call_args.args[0]
    assert message.startswith("runtime_event ")
    payload = json.loads(message.removeprefix("runtime_event "))
    assert payload["event"] == "transcribe_finished"
    assert payload["char_count"] == 18


@pytest.mark.parametrize("field", ["text", "raw_transcript", "initial_prompt", "clipboard_value"])
def test_runtime_event_rejects_sensitive_fields(field: str) -> None:
    with pytest.raises(ValueError):
        emit_runtime_event("bad", **{field: "secret"})


def test_analyzer_reports_latency_and_out_of_order_chunks(tmp_path: Path) -> None:
    log_path = tmp_path / "app.log"
    lines = [
        '2026-06-30 12:00:00,000 - INFO - runtime_event {"event":"transcribe_finished","duration_seconds":2.0}\n',
        '2026-06-30 12:00:01,000 - INFO - runtime_event {"event":"transcribe_finished","duration_seconds":4.0}\n',
        '2026-06-30 12:00:02,000 - INFO - runtime_event {"event":"chunk_dequeued","session_id":7,"chunk_index":2}\n',
        '2026-06-30 12:00:03,000 - INFO - runtime_event {"event":"chunk_dequeued","session_id":7,"chunk_index":1}\n',
    ]
    log_path.write_text("".join(lines), encoding="utf-8")

    events = load_events(log_path, datetime(2026, 6, 30))
    summary = summarize_events(events)

    assert summary["latency"]["transcribe_finished"]["p50"] == 3.0
    assert summary["out_of_order_sessions"] == {7: [2, 1]}
