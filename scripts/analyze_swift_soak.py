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
SENSITIVE_FIELD_NAMES = {"key", "secret"}
SessionKey = tuple[str, int]
WorkloadKey = tuple[str, str, str, str, str]


def percentile(values: Iterable[float], percentile_value: float) -> float | None:
    ordered = sorted(float(value) for value in values if math.isfinite(float(value)))
    if not ordered:
        return None
    rank = max(0, math.ceil((percentile_value / 100.0) * len(ordered)) - 1)
    return ordered[rank]


def sensitive_field_paths(value: Any, path: tuple[str, ...] = ()) -> list[str]:
    paths: list[str] = []
    if isinstance(value, dict):
        for raw_key, nested in value.items():
            key = str(raw_key)
            nested_path = (*path, key)
            lowered = key.lower()
            if (
                lowered in SENSITIVE_FIELD_NAMES
                or lowered.endswith(("_key", "_secret"))
                or any(part in lowered for part in SENSITIVE_FIELD_PARTS)
            ):
                paths.append(".".join(nested_path))
            paths.extend(sensitive_field_paths(nested, nested_path))
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            paths.extend(sensitive_field_paths(nested, (*path, str(index))))
    return paths


def run_id(event: dict[str, Any]) -> str | None:
    value = event.get("run_id")
    if not isinstance(value, str) or not value.strip():
        return None
    return value


def session_key(event: dict[str, Any]) -> SessionKey | None:
    run = run_id(event)
    session_id = event.get("session_id")
    if run is None or isinstance(session_id, bool) or not isinstance(session_id, int):
        return None
    return run, session_id


def workload_key(event: dict[str, Any], run: str) -> WorkloadKey:
    return (
        run,
        str(event.get("stt_backend", "unknown")),
        str(event.get("stt_model", "unknown")),
        str(event.get("ai_backend", "unknown")),
        str(event.get("ai_model", "unknown")),
    )


def runtime_duration_seconds(events: list[dict[str, Any]]) -> float:
    by_run: dict[str, list[float]] = defaultdict(list)
    for event in events:
        run = run_id(event)
        if run is None:
            continue
        value = event.get("monotonic")
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        numeric = float(value)
        if math.isfinite(numeric):
            by_run[run].append(numeric)
    return sum(max(values) - min(values) for values in by_run.values() if len(values) >= 2)


def session_integrity(events: list[dict[str, Any]]) -> dict[str, int]:
    starts: Counter[SessionKey] = Counter()
    outcomes: Counter[SessionKey] = Counter()
    chunks: dict[SessionKey, list[int]] = defaultdict(list)
    incomplete: set[SessionKey] = set()
    no_speech: set[SessionKey] = set()
    failed_chunk_count = 0
    append_sessions: set[SessionKey] = set()
    identity_error_count = 0

    for event in events:
        if run_id(event) is None:
            identity_error_count += 1
            continue
        name = event.get("event")
        if name not in {
            "session_start", "session_end", "session_incomplete", "chunk_processed"
        }:
            continue
        key = session_key(event)
        if key is None:
            identity_error_count += 1
            continue
        if name == "session_start":
            starts[key] += 1
            if event.get("append_mode") is True:
                append_sessions.add(key)
        elif name == "session_end":
            outcomes[key] += 1
        elif name == "session_incomplete":
            incomplete.add(key)
        elif name == "chunk_processed":
            index = event.get("chunk_index")
            if isinstance(index, bool) or not isinstance(index, int):
                identity_error_count += 1
            else:
                chunks[key].append(index)
            outcome = str(event.get("outcome", "unknown"))
            if outcome == "no_speech":
                no_speech.add(key)
            elif (
                outcome in {"timed_out", "aborted", "failed"}
                or outcome.startswith("failed_")
            ):
                failed_chunk_count += 1

    duplicate_start_count = sum(max(0, count - 1) for count in starts.values())
    missing_outcome_count = sum(1 for key in starts if outcomes[key] == 0)
    duplicate_outcome_count = sum(max(0, count - 1) for count in outcomes.values())
    orphan_outcome_count = sum(count for key, count in outcomes.items() if key not in starts)
    orphan_chunk_count = sum(len(indices) for key, indices in chunks.items() if key not in starts)
    sequence_error_count = 0
    for key, indices in chunks.items():
        if not indices:
            continue
        if key not in append_sessions and indices[0] != 0:
            sequence_error_count += 1
        sequence_error_count += sum(
            1
            for previous, current in zip(indices, indices[1:], strict=False)
            if current != previous + 1
        )

    integrity_error_count = (
        identity_error_count
        + duplicate_start_count
        + missing_outcome_count
        + duplicate_outcome_count
        + orphan_outcome_count
        + orphan_chunk_count
        + sequence_error_count
        + len(incomplete)
        + failed_chunk_count
    )
    return {
        "session_start_count": sum(starts.values()),
        "session_outcome_count": sum(outcomes.values()),
        "duplicate_session_start_count": duplicate_start_count,
        "missing_session_outcome_count": missing_outcome_count,
        "duplicate_session_outcome_count": duplicate_outcome_count,
        "orphan_session_outcome_count": orphan_outcome_count,
        "orphan_chunk_count": orphan_chunk_count,
        "incomplete_session_count": len(incomplete),
        "failed_chunk_count": failed_chunk_count,
        "no_speech_session_count": len(no_speech),
        "chunk_sequence_error_count": sequence_error_count,
        "identity_error_count": identity_error_count,
        "session_integrity_error_count": integrity_error_count,
    }


def rss_summary(events: list[dict[str, Any]]) -> tuple[float | None, float | None]:
    snapshots: dict[str, list[tuple[WorkloadKey, int, float] | None]] = defaultdict(list)
    all_rss: list[float] = []
    for event in events:
        if event.get("event") != "process_snapshot":
            continue
        run = run_id(event)
        if run is None:
            continue
        rss = event.get("parent_rss_mb")
        completed = event.get("completed_sessions")
        if (
            isinstance(rss, bool)
            or not isinstance(rss, (int, float))
            or not math.isfinite(float(rss))
        ):
            snapshots[run].append(None)
            continue
        numeric_rss = float(rss)
        all_rss.append(numeric_rss)
        if isinstance(completed, bool) or not isinstance(completed, int):
            snapshots[run].append(None)
            continue
        snapshots[run].append((workload_key(event, run), completed, numeric_rss))

    normalized_growth: list[float] = []
    for run_snapshots in snapshots.values():
        segment_start: tuple[WorkloadKey, int, float] | None = None
        segment_end: tuple[WorkloadKey, int, float] | None = None
        for current in [*run_snapshots, None]:
            if current is None:
                if segment_start is not None and segment_end is not None:
                    completed_delta = segment_end[1] - segment_start[1]
                    if completed_delta > 0:
                        normalized_growth.append(
                            (segment_end[2] - segment_start[2])
                            * 100.0
                            / completed_delta
                        )
                segment_start = None
                segment_end = None
                continue
            if segment_start is None or segment_end is None:
                segment_start = current
                segment_end = current
                continue
            if current[0] == segment_end[0] and current[1] > segment_end[1]:
                segment_end = current
                continue
            completed_delta = segment_end[1] - segment_start[1]
            if completed_delta > 0:
                normalized_growth.append(
                    (segment_end[2] - segment_start[2]) * 100.0 / completed_delta
                )
            segment_start = current
            segment_end = current
    return (
        max(all_rss) if all_rss else None,
        max(normalized_growth) if normalized_growth else None,
    )


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
            forbidden = sensitive_field_paths(payload)
            if forbidden:
                raise ValueError(
                    f"Sensitive telemetry field name at line {line_number}: {sorted(forbidden)}"
                )
            events.append(payload)
    return events


def summarize(events: list[dict[str, Any]]) -> dict[str, Any]:
    wall_clock = [
        float(event["wall_clock"])
        for event in events
        if isinstance(event.get("wall_clock"), (int, float))
        and not isinstance(event.get("wall_clock"), bool)
        and math.isfinite(float(event["wall_clock"]))
    ]
    by_name = Counter(str(event.get("event", "unknown")) for event in events)
    session_ids: set[SessionKey] = {
        key
        for event in events
        if event.get("event") == "session_start"
        if (key := session_key(event)) is not None
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
        and event.get("backend") == "local"
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

    peak_rss, rss_growth = rss_summary(events)
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
    result = {
        "event_count": len(events),
        "event_counts": dict(sorted(by_name.items())),
        "duration_hours": runtime_duration_seconds(events) / 3600.0,
        "wall_clock_start": min(wall_clock) if wall_clock else None,
        "wall_clock_end": max(wall_clock) if wall_clock else None,
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
        "peak_rss_mb": peak_rss,
        "rss_growth_mb": rss_growth,
        "audio_callback_p95_ms": percentile(callback_maxima, 95),
        "audio_callback_metric_basis": "session_maxima",
        "audio_overflow_count": overflow_samples,
    }
    result.update(session_integrity(events))
    return result


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
    if summary["session_integrity_error_count"] > 0:
        failures.append("session_integrity")
    for key in {
        "hotkey_to_hud_p95_seconds",
        "stop_to_popup_p95_seconds",
        "local_editor_p95_seconds",
        "peak_rss_mb",
        "audio_callback_p95_ms",
        "audio_overflow_count",
    }:
        merged_metrics[key] = summary[key]
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
