"""Summarize a privacy-safe Swift runtime-event log for the Epoch 10 soak gate."""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable, Iterable

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


def finite_uptime(event: dict[str, Any]) -> float | None:
    value = event.get("monotonic")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    uptime = float(value)
    return uptime if math.isfinite(uptime) else None


def delay_after_stop_ms(
    stop_uptime: float | None,
    presentation_uptime: float | None,
) -> float | None:
    if stop_uptime is None or presentation_uptime is None:
        return None
    if not math.isfinite(stop_uptime) or not math.isfinite(presentation_uptime):
        return None
    return max(0.0, presentation_uptime - stop_uptime) * 1000.0


def strictly_after_stop_ms(
    stop_uptime: float | None,
    presentation_uptime: float | None,
) -> float | None:
    """Return a delay only when the event is not recorded before Stop."""
    if stop_uptime is None or presentation_uptime is None:
        return None
    if not math.isfinite(stop_uptime) or not math.isfinite(presentation_uptime):
        return None
    if presentation_uptime < stop_uptime:
        return None
    return (presentation_uptime - stop_uptime) * 1000.0


def correlated_delays(
    events: list[dict[str, Any]],
    event_name: str,
    include: Callable[[dict[str, Any]], bool] | None = None,
    count_missing_presentations: bool = True,
    allow_pre_stop: bool = True,
) -> tuple[list[float], int]:
    stops: dict[SessionKey, float | None] = {}
    presentations: dict[SessionKey, list[float | None]] = defaultdict(list)

    for event in events:
        key = session_key(event)
        if key is None:
            continue
        if event.get("event") == "session_stop":
            stops.setdefault(key, finite_uptime(event))
        elif event.get("event") == event_name and (include is None or include(event)):
            presentations[key].append(finite_uptime(event))

    delays: list[float] = []
    incomplete = 0
    for key, stop_uptime in stops.items():
        observed = presentations.pop(key, [])
        if not observed:
            if count_missing_presentations:
                incomplete += 1
            continue
        presentation_uptime = next((uptime for uptime in observed if uptime is not None), None)
        delay = (
            delay_after_stop_ms(stop_uptime, presentation_uptime)
            if allow_pre_stop
            else strictly_after_stop_ms(stop_uptime, presentation_uptime)
        )
        if delay is None:
            incomplete += 1
        else:
            delays.append(delay / 1000.0)

    incomplete += sum(len(values) for values in presentations.values())
    return delays, incomplete


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
            "session_start",
            "session_stop",
            "first_preview_presented",
            "draft_preview_presented",
            "session_end",
            "session_incomplete",
            "chunk_processed",
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
            elif outcome in {"timed_out", "aborted", "failed"} or outcome.startswith("failed_"):
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
            1 for previous, current in zip(indices, indices[1:], strict=False) if current != previous + 1
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


def confirmed_sessions(events: list[dict[str, Any]]) -> set[SessionKey]:
    return {
        key
        for event in events
        if event.get("event") == "session_end" and event.get("reason") == "confirm"
        if (key := session_key(event)) is not None
    }


def successful_confirmed_sessions(events: list[dict[str, Any]]) -> set[SessionKey]:
    confirmed: set[SessionKey] = set()
    unsuccessful: set[SessionKey] = set()
    successful_speech: set[SessionKey] = set()
    for event in events:
        key = session_key(event)
        if key is None:
            continue
        name = event.get("event")
        if name == "session_end" and event.get("reason") == "confirm":
            confirmed.add(key)
        elif name == "session_incomplete":
            unsuccessful.add(key)
        elif name == "chunk_processed":
            outcome = str(event.get("outcome", "unknown"))
            if outcome == "success":
                successful_speech.add(key)
            if outcome in {"timed_out", "aborted", "failed"} or outcome.startswith("failed_"):
                unsuccessful.add(key)
    return confirmed & successful_speech - unsuccessful


def timing_event_integrity(events: list[dict[str, Any]]) -> dict[str, int]:
    required_events: dict[str, Callable[[dict[str, Any]], bool]] = {
        "session_stop": lambda event: event.get("event") == "session_stop",
        "first_preview": lambda event: event.get("event") == "first_preview_presented",
        "draft_preview": lambda event: event.get("event") == "draft_preview_presented",
        "confirm_end": lambda event: (event.get("event") == "session_end" and event.get("reason") == "confirm"),
    }
    counts: dict[str, Counter[SessionKey]] = {label: Counter() for label in required_events}
    timestamps: dict[str, dict[SessionKey, list[float | None]]] = {
        label: defaultdict(list) for label in required_events
    }
    starts: Counter[SessionKey] = Counter()
    for event in events:
        if event.get("event") == "session_start":
            if (key := session_key(event)) is not None:
                starts[key] += 1
        for label, predicate in required_events.items():
            if not predicate(event):
                continue
            key = session_key(event)
            if key is not None:
                counts[label][key] += 1
                timestamps[label][key].append(finite_uptime(event))

    result: dict[str, int] = {}
    applicable_sessions = confirmed_sessions(events)
    for label in required_events:
        applicable_counts = [counts[label][key] for key in applicable_sessions]
        result[f"missing_{label}_count"] = sum(count == 0 for count in applicable_counts)
        result[f"duplicate_{label}_count"] = sum(max(0, count - 1) for count in counts[label].values())
        result[f"invalid_{label}_timestamp_count"] = sum(
            sum(timestamp is None for timestamp in timestamps[label][key]) for key in applicable_sessions
        )
        result[f"orphan_{label}_count"] = sum(count for key, count in counts[label].items() if key not in starts)

    result["draft_preview_without_stop_count"] = sum(
        1
        for key, count in counts["draft_preview"].items()
        if key in starts and count > 0 and counts["session_stop"][key] == 0
    )
    for label, key_name in (
        ("draft_preview", "draft_preview_before_stop_count"),
        ("confirm_end", "confirm_end_before_stop_count"),
    ):
        result[key_name] = sum(
            1
            for key in applicable_sessions
            if len(timestamps["session_stop"][key]) == 1
            and len(timestamps[label][key]) == 1
            and timestamps["session_stop"][key][0] is not None
            and timestamps[label][key][0] is not None
            and timestamps[label][key][0] < timestamps["session_stop"][key][0]
        )
    result["timing_event_integrity_error_count"] = sum(result.values())
    return result


def timing_values_by_session(events: list[dict[str, Any]]) -> dict[SessionKey, dict[str, float | None]]:
    event_names = {
        "session_stop": "stop",
        "first_preview_presented": "first_preview",
        "draft_preview_presented": "draft_preview",
        "session_end": "enter",
    }
    times: dict[SessionKey, dict[str, list[float | None]]] = defaultdict(lambda: defaultdict(list))
    for event in events:
        key = session_key(event)
        name = event.get("event")
        if key is None or name not in event_names:
            continue
        if name == "session_end" and event.get("reason") != "confirm":
            continue
        times[key][event_names[name]].append(finite_uptime(event))

    values: dict[SessionKey, dict[str, float | None]] = {}
    for key in successful_confirmed_sessions(events):
        session_times = times[key]
        stop = session_times.get("stop", [])
        if len(stop) != 1:
            values[key] = {
                "first_preview": None,
                "draft_preview": None,
                "enter": None,
            }
            continue
        values[key] = {}
        for name in ("first_preview", "draft_preview", "enter"):
            presentations = session_times.get(name, [])
            delay = (
                (
                    delay_after_stop_ms(stop[0], presentations[0])
                    if name == "first_preview"
                    else strictly_after_stop_ms(stop[0], presentations[0])
                )
                if len(presentations) == 1
                else None
            )
            values[key][name] = delay / 1_000.0 if delay is not None else None
    return values


def sample_count_bucket(sample_count: int | None) -> str:
    if sample_count is None:
        return "unknown"
    if sample_count <= 16_000:
        return "short_<=16000"
    if sample_count <= 64_000:
        return "medium_<=64000"
    return "long_>64000"


def latency_breakdowns(events: list[dict[str, Any]]) -> dict[str, dict[str, dict[str, float | int | None]]]:
    timings = timing_values_by_session(events)
    models: dict[SessionKey, set[str]] = defaultdict(set)
    samples: dict[SessionKey, int] = defaultdict(int)
    has_sample_count: set[SessionKey] = set()
    missing_model_metadata: set[SessionKey] = set()
    missing_sample_metadata: set[SessionKey] = set()
    append_modes: dict[SessionKey, bool] = {}
    for event in events:
        key = session_key(event)
        if key not in timings:
            continue
        if event.get("event") == "session_start" and isinstance(event.get("append_mode"), bool):
            append_modes[key] = event["append_mode"]
        if event.get("event") == "chunk_processed":
            model = event.get("stt_model")
            if isinstance(model, str) and model:
                models[key].add(model)
            else:
                missing_model_metadata.add(key)
            sample_count = event.get("sample_count")
            if isinstance(sample_count, int) and not isinstance(sample_count, bool) and sample_count >= 0:
                samples[key] += sample_count
                has_sample_count.add(key)
            else:
                missing_sample_metadata.add(key)

    grouped: dict[str, dict[str, list[dict[str, float | None]]]] = {
        "by_stt_model": defaultdict(list),
        "by_append_mode": defaultdict(list),
        "by_sample_count_bucket": defaultdict(list),
    }
    for key, values in timings.items():
        model_names = models[key]
        model = (
            "unknown"
            if key in missing_model_metadata
            else (next(iter(model_names)) if len(model_names) == 1 else ("mixed" if model_names else "unknown"))
        )
        append_mode = (
            "append" if append_modes.get(key) is True else ("new" if append_modes.get(key) is False else "unknown")
        )
        sample_count = samples[key] if key in has_sample_count and key not in missing_sample_metadata else None
        grouped["by_stt_model"][model].append(values)
        grouped["by_append_mode"][append_mode].append(values)
        grouped["by_sample_count_bucket"][sample_count_bucket(sample_count)].append(values)

    result: dict[str, dict[str, dict[str, float | int | None]]] = {}
    for dimension, groups in grouped.items():
        result[dimension] = {}
        for group, values in sorted(groups.items()):
            summary: dict[str, float | int | None] = {"count": len(values), "n": len(values)}
            for metric, output_name in (
                ("first_preview", "first_preview"),
                ("draft_preview", "preview"),
                ("enter", "enter"),
            ):
                observed = [value[metric] for value in values if value[metric] is not None]
                summary[f"stop_to_{output_name}_p50_seconds"] = percentile(observed, 50)
                summary[f"stop_to_{output_name}_p95_seconds"] = percentile(observed, 95)
            result[dimension][group] = summary
    result["chunk_queue_wait"] = event_latency_breakdowns(
        events,
        event_name="chunk_processed",
        value_field="queue_wait_ms",
        model_field="stt_model",
        sample_bucket_dimension="by_sample_count_bucket",
    )
    result["stt_request"] = event_latency_breakdowns(
        events,
        event_name="chunk_processed",
        value_field="request_ms",
        model_field="stt_model",
        sample_bucket_dimension="by_sample_count_bucket",
    )
    result["local_editor_latency"] = local_editor_latency_breakdowns(events)
    return result


def finite_number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    numeric = float(value)
    return numeric if math.isfinite(numeric) else None


def append_modes_by_session(events: list[dict[str, Any]]) -> dict[SessionKey, str]:
    modes: dict[SessionKey, str] = {}
    for event in events:
        key = session_key(event)
        if key is None or not isinstance(event.get("append_mode"), bool):
            continue
        modes.setdefault(key, "append" if event["append_mode"] else "new")
    return modes


def event_latency_breakdowns(
    events: list[dict[str, Any]],
    event_name: str,
    value_field: str,
    model_field: str,
    sample_bucket_dimension: str,
) -> dict[str, dict[str, dict[str, float | int | None]]]:
    append_modes = append_modes_by_session(events)
    groups: dict[str, dict[str, list[float]]] = {
        "by_stt_model": defaultdict(list),
        "by_append_mode": defaultdict(list),
        sample_bucket_dimension: defaultdict(list),
    }
    for event in events:
        if event.get("event") != event_name:
            continue
        value = finite_number(event.get(value_field))
        if value is None:
            continue
        key = session_key(event)
        model = event.get(model_field)
        model_name = model if isinstance(model, str) and model else "unknown"
        append_mode = append_modes.get(key, "unknown") if key is not None else "unknown"
        sample_count = event.get("sample_count")
        sample_value = (
            sample_count
            if isinstance(sample_count, int) and not isinstance(sample_count, bool) and sample_count >= 0
            else None
        )
        seconds = value / 1_000.0
        groups["by_stt_model"][model_name].append(seconds)
        groups["by_append_mode"][append_mode].append(seconds)
        groups[sample_bucket_dimension][sample_count_bucket(sample_value)].append(seconds)
    return {
        dimension: {
            group: {
                "n": len(values),
                "p50_seconds": percentile(values, 50),
                "p95_seconds": percentile(values, 95),
            }
            for group, values in sorted(grouped.items())
        }
        for dimension, grouped in groups.items()
    }


def local_editor_latency_breakdowns(
    events: list[dict[str, Any]],
) -> dict[str, dict[str, dict[str, float | int | None]]]:
    append_modes = append_modes_by_session(events)
    session_samples: dict[SessionKey, int] = defaultdict(int)
    sessions_with_samples: set[SessionKey] = set()
    sessions_with_missing_samples: set[SessionKey] = set()
    for event in events:
        if event.get("event") != "chunk_processed":
            continue
        key = session_key(event)
        sample_count = event.get("sample_count")
        if (
            key is not None
            and isinstance(sample_count, int)
            and not isinstance(sample_count, bool)
            and sample_count >= 0
        ):
            session_samples[key] += sample_count
            sessions_with_samples.add(key)
        elif key is not None:
            sessions_with_missing_samples.add(key)
    groups: dict[str, dict[str, list[float]]] = {
        "by_editor_model": defaultdict(list),
        "by_append_mode": defaultdict(list),
        "by_workload_bucket": defaultdict(list),
    }
    for event in events:
        if (
            event.get("event") != "editor_refine"
            or event.get("editor_backend") != "local"
            or event.get("outcome") not in {"ok", "unchanged"}
        ):
            continue
        value = finite_number(event.get("editor_latency_ms"))
        if value is None:
            continue
        key = session_key(event)
        model = event.get("editor_model")
        model_name = model if isinstance(model, str) and model else "unknown"
        append_mode = append_modes.get(key, "unknown") if key is not None else "unknown"
        sample_count = (
            session_samples[key] if key in sessions_with_samples and key not in sessions_with_missing_samples else None
        )
        bucket = sample_count_bucket(sample_count) if sample_count is not None else "unknown_editor_workload"
        seconds = value / 1_000.0
        groups["by_editor_model"][model_name].append(seconds)
        groups["by_append_mode"][append_mode].append(seconds)
        groups["by_workload_bucket"][bucket].append(seconds)
    return {
        dimension: {
            group: {
                "n": len(values),
                "p50_seconds": percentile(values, 50),
                "p95_seconds": percentile(values, 95),
            }
            for group, values in sorted(grouped.items())
        }
        for dimension, grouped in groups.items()
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
        if isinstance(rss, bool) or not isinstance(rss, (int, float)) or not math.isfinite(float(rss)):
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
                        normalized_growth.append((segment_end[2] - segment_start[2]) * 100.0 / completed_delta)
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
                normalized_growth.append((segment_end[2] - segment_start[2]) * 100.0 / completed_delta)
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
            payload = json.loads(line[marker_index + len(marker) :])
            if not isinstance(payload, dict):
                raise ValueError(f"Runtime event is not an object at line {line_number}")
            forbidden = sensitive_field_paths(payload)
            if forbidden:
                raise ValueError(f"Sensitive telemetry field name at line {line_number}: {sorted(forbidden)}")
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
        key for event in events if event.get("event") == "session_start" if (key := session_key(event)) is not None
    }
    hud = [
        float(event["hud_latency_ms"]) / 1000.0
        for event in events
        if event.get("event") == "session_start" and isinstance(event.get("hud_latency_ms"), (int, float))
    ]
    popup = [
        float(event["stop_to_popup_ms"]) / 1000.0
        for event in events
        if event.get("event") == "popup_presented" and isinstance(event.get("stop_to_popup_ms"), (int, float))
    ]
    editor = [
        float(event["editor_latency_ms"]) / 1000.0
        for event in events
        if event.get("event") == "editor_refine"
        and event.get("editor_backend") == "local"
        and event.get("outcome") in {"ok", "unchanged"}
        and isinstance(event.get("editor_latency_ms"), (int, float))
    ]
    editor_statuses = Counter(
        str(event.get("outcome", "unknown")) for event in events if event.get("event") == "editor_refine"
    )
    local_editor_statuses = Counter(
        str(event.get("outcome", "unknown"))
        for event in events
        if event.get("event") == "editor_refine" and event.get("editor_backend") == "local"
    )
    first_preview, incomplete_first_preview_count = correlated_delays(events, "first_preview_presented")
    draft_preview, incomplete_draft_preview_count = correlated_delays(
        events, "draft_preview_presented", allow_pre_stop=False
    )
    enter, incomplete_enter_count = correlated_delays(
        events,
        "session_end",
        include=lambda event: event.get("reason") == "confirm",
        count_missing_presentations=False,
        allow_pre_stop=False,
    )
    queue_wait = [
        float(event["queue_wait_ms"]) / 1000.0
        for event in events
        if event.get("event") == "chunk_processed" and isinstance(event.get("queue_wait_ms"), (int, float))
    ]
    stt_request = [
        float(event["request_ms"]) / 1000.0
        for event in events
        if event.get("event") == "chunk_processed" and isinstance(event.get("request_ms"), (int, float))
    ]
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
        if event.get("event") == "audio_capture_stats" and isinstance(event.get("maximum_callback_ms"), (int, float))
    ]
    overflow_samples = sum(
        int(event["overflow_samples"])
        for event in events
        if event.get("event") == "audio_capture_stats" and isinstance(event.get("overflow_samples"), int)
    )
    result = {
        "event_count": len(events),
        "event_counts": dict(sorted(by_name.items())),
        "duration_hours": runtime_duration_seconds(events) / 3600.0,
        "wall_clock_start": min(wall_clock) if wall_clock else None,
        "wall_clock_end": max(wall_clock) if wall_clock else None,
        "session_count": len(session_ids),
        "session_error_count": by_name.get("session_error", 0),
        "incomplete_first_preview_count": incomplete_first_preview_count,
        "incomplete_draft_preview_count": incomplete_draft_preview_count,
        "incomplete_enter_count": incomplete_enter_count,
        "hotkey_to_hud_p95_seconds": percentile(hud, 95),
        "stop_to_first_preview_p50_seconds": percentile(first_preview, 50),
        "stop_to_first_preview_p95_seconds": percentile(first_preview, 95),
        "stop_to_preview_p50_seconds": percentile(draft_preview, 50),
        "stop_to_preview_p95_seconds": percentile(draft_preview, 95),
        "stop_to_popup_p50_seconds": percentile(popup, 50),
        "stop_to_popup_p95_seconds": percentile(popup, 95),
        "stop_to_enter_p50_seconds": percentile(enter, 50),
        "stop_to_enter_p95_seconds": percentile(enter, 95),
        "chunk_queue_wait_p50_seconds": percentile(queue_wait, 50),
        "chunk_queue_wait_p95_seconds": percentile(queue_wait, 95),
        "stt_request_p50_seconds": percentile(stt_request, 50),
        "stt_request_p95_seconds": percentile(stt_request, 95),
        "local_editor_p95_seconds": percentile(editor, 95),
        "editor_status_distribution": dict(sorted(editor_statuses.items())),
        "local_editor_outcome_counts": dict(sorted(local_editor_statuses.items())),
        "latency_breakdowns": latency_breakdowns(events),
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
    result.update(timing_event_integrity(events))
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
    if summary["timing_event_integrity_error_count"] > 0:
        failures.append("timing_event_integrity")
    for key in {
        "hotkey_to_hud_p95_seconds",
        "stop_to_first_preview_p95_seconds",
        "stop_to_preview_p95_seconds",
        "stop_to_popup_p95_seconds",
        "stop_to_enter_p95_seconds",
        "chunk_queue_wait_p95_seconds",
        "stt_request_p95_seconds",
        "local_editor_p95_seconds",
        "peak_rss_mb",
        "audio_callback_p95_ms",
        "audio_overflow_count",
    }:
        merged_metrics[key] = summary.get(key)
    merged_metrics["rss_growth_100_sessions_mb"] = summary.get("rss_growth_mb")
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
