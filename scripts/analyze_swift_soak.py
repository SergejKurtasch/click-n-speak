"""Summarize a privacy-safe Swift runtime-event log for the Epoch 10 soak gate."""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

LOGGER = logging.getLogger("analyze_swift_soak")
SENSITIVE_FIELD_PARTS = {"text", "transcript", "prompt", "clipboard", "audio"}


def percentile(values: Iterable[float], percentile_value: float) -> float | None:
    ordered = sorted(float(value) for value in values if math.isfinite(float(value)))
    if not ordered:
        return None
    rank = max(0, math.ceil((percentile_value / 100.0) * len(ordered)) - 1)
    return ordered[rank]


def parse_runtime_events(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    marker = "runtime_event "
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line_number, line in enumerate(handle, 1):
            marker_index = line.find(marker)
            if marker_index < 0:
                continue
            payload = json.loads(line[marker_index + len(marker):])
            if not isinstance(payload, dict):
                raise ValueError(f"Runtime event is not an object at line {line_number}")
            forbidden = [
                key
                for key in payload
                if any(part in key.lower() for part in SENSITIVE_FIELD_PARTS)
            ]
            if forbidden:
                raise ValueError(
                    f"Sensitive telemetry field name at line {line_number}: {sorted(forbidden)}"
                )
            events.append(payload)
    return events


def summarize(events: list[dict[str, Any]]) -> dict[str, Any]:
    monotonic = [
        float(event["monotonic"])
        for event in events
        if isinstance(event.get("monotonic"), (int, float))
    ]
    by_name = Counter(str(event.get("event", "unknown")) for event in events)
    session_ids = {
        int(event["session_id"])
        for event in events
        if event.get("event") == "session_start" and isinstance(event.get("session_id"), int)
    }
    hud = [
        float(event["hud_latency_ms"]) / 1000.0
        for event in events
        if event.get("event") == "session_start"
        and isinstance(event.get("hud_latency_ms"), (int, float))
    ]
    popup = [
        float(event["stop_to_popup_ms"]) / 1000.0
        for event in events
        if event.get("event") == "popup_presented"
        and isinstance(event.get("stop_to_popup_ms"), (int, float))
    ]
    editor = [
        float(event["duration_ms"]) / 1000.0
        for event in events
        if event.get("event") == "editor_refine"
        and isinstance(event.get("duration_ms"), (int, float))
    ]
    editor_statuses = Counter(
        str(event.get("status", "unknown"))
        for event in events
        if event.get("event") == "editor_refine"
    )
    cloud_latencies: dict[str, list[float]] = defaultdict(list)
    for event in events:
        if event.get("event") != "chunk_processed":
            continue
        backend = str(event.get("stt_backend", "unknown"))
        duration = event.get("duration_ms")
        if backend != "local" and isinstance(duration, (int, float)):
            cloud_latencies[backend].append(float(duration) / 1000.0)

    rss = [
        float(event["parent_rss_mb"])
        for event in events
        if event.get("event") == "process_snapshot"
        and isinstance(event.get("parent_rss_mb"), (int, float))
    ]
    callback_maxima = [
        float(event["maximum_callback_ms"])
        for event in events
        if event.get("event") == "audio_capture_stats"
        and isinstance(event.get("maximum_callback_ms"), (int, float))
    ]
    overflow_samples = sum(
        int(event["overflow_samples"])
        for event in events
        if event.get("event") == "audio_capture_stats"
        and isinstance(event.get("overflow_samples"), int)
    )
    return {
        "event_count": len(events),
        "event_counts": dict(sorted(by_name.items())),
        "duration_hours": ((max(monotonic) - min(monotonic)) / 3600.0) if len(monotonic) >= 2 else 0.0,
        "session_count": len(session_ids),
        "session_error_count": by_name.get("session_error", 0),
        "hotkey_to_hud_p95_seconds": percentile(hud, 95),
        "stop_to_popup_p50_seconds": percentile(popup, 50),
        "stop_to_popup_p95_seconds": percentile(popup, 95),
        "local_editor_p95_seconds": percentile(editor, 95),
        "editor_status_distribution": dict(sorted(editor_statuses.items())),
        "cloud_latency_seconds": {
            backend: {
                "count": len(values),
                "p50": percentile(values, 50),
                "p95": percentile(values, 95),
            }
            for backend, values in sorted(cloud_latencies.items())
        },
        "peak_rss_mb": max(rss) if rss else None,
        "rss_growth_mb": (rss[-1] - rss[0]) if len(rss) >= 2 else None,
        "audio_callback_p95_ms": percentile(callback_maxima, 95),
        "audio_overflow_count": overflow_samples,
    }


def load_optional_metrics(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    metrics = payload.get("metrics") if isinstance(payload, dict) else None
    if not isinstance(metrics, dict):
        raise ValueError("Quality metrics document must contain a metrics object")
    return metrics


def write_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--quality-metrics", type=Path)
    parser.add_argument("--minimum-hours", type=float, default=8.0)
    parser.add_argument("--minimum-sessions", type=int, default=100)
    parser.add_argument("--maximum-session-errors", type=int, default=0)
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = parse_args()
    try:
        summary = summarize(parse_runtime_events(args.log))
        merged_metrics = load_optional_metrics(args.quality_metrics)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        LOGGER.error("Soak evidence is invalid: %s", error)
        return 2

    failures: list[str] = []
    if summary["duration_hours"] < args.minimum_hours:
        failures.append("duration_hours")
    if summary["session_count"] < args.minimum_sessions:
        failures.append("session_count")
    if summary["session_error_count"] > args.maximum_session_errors:
        failures.append("session_error_count")
    merged_metrics.update(
        {
            key: value
            for key, value in summary.items()
            if key
            in {
                "hotkey_to_hud_p95_seconds",
                "stop_to_popup_p95_seconds",
                "local_editor_p95_seconds",
                "peak_rss_mb",
                "audio_callback_p95_ms",
                "audio_overflow_count",
            }
            and value is not None
        }
    )
    if summary["rss_growth_mb"] is not None:
        merged_metrics["rss_growth_100_sessions_mb"] = summary["rss_growth_mb"]
    document = {
        "schema_version": 1,
        "status": "passed" if not failures else "failed",
        "failures": failures,
        "summary": summary,
        "metrics": merged_metrics,
    }
    write_atomic(args.output, document)
    LOGGER.info("Soak summary %s: %s", document["status"], args.output)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
