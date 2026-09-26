#!/usr/bin/env python3
import argparse
import json
import logging
import math
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

_LOG_PREFIX = " - INFO - runtime_event "


def percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] * (upper - position) + ordered[upper] * (position - lower)


def load_events(path: Path, since: datetime) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if _LOG_PREFIX not in line:
                    continue
                timestamp_raw, payload_raw = line.split(_LOG_PREFIX, 1)
                try:
                    timestamp = datetime.strptime(timestamp_raw, "%Y-%m-%d %H:%M:%S,%f")
                    payload = json.loads(payload_raw)
                except (ValueError, json.JSONDecodeError):
                    continue
                if timestamp >= since:
                    payload["timestamp"] = timestamp
                    events.append(payload)
    except OSError as exc:
        logging.error("Could not read runtime log %s: %s", path, exc)
    return events


def summarize_events(events: list[dict[str, Any]]) -> dict[str, Any]:
    durations: dict[str, list[float]] = defaultdict(list)
    counts = Counter(str(event.get("event", "unknown")) for event in events)
    chunk_indices: dict[int, list[int]] = defaultdict(list)
    for event in events:
        name = str(event.get("event", "unknown"))
        duration = event.get("duration_seconds")
        if isinstance(duration, (int, float)):
            durations[name].append(float(duration))
        if name == "chunk_dequeued":
            session_id = event.get("session_id")
            chunk_index = event.get("chunk_index")
            if isinstance(session_id, int) and isinstance(chunk_index, int):
                chunk_indices[session_id].append(chunk_index)

    out_of_order = {
        session_id: indices
        for session_id, indices in chunk_indices.items()
        if indices != sorted(indices)
    }
    latency = {
        name: {
            "count": len(values),
            "p50": percentile(values, 0.5),
            "p90": percentile(values, 0.9),
            "p95": percentile(values, 0.95),
            "max": max(values),
        }
        for name, values in sorted(durations.items())
    }
    return {
        "event_counts": dict(sorted(counts.items())),
        "latency": latency,
        "out_of_order_sessions": out_of_order,
    }


def main() -> None:
    from src.utils import get_log_file_path

    parser = argparse.ArgumentParser(description="Analyze Click-n-speak runtime telemetry.")
    parser.add_argument("--days", type=int, default=14)
    parser.add_argument("--log", type=Path, default=get_log_file_path())
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    events = load_events(args.log, datetime.now() - timedelta(days=max(args.days, 1)))
    summary = summarize_events(events)
    logging.info(json.dumps(summary, ensure_ascii=False, indent=2, default=str))


if __name__ == "__main__":
    main()
