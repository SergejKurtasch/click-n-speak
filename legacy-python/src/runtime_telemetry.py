import json
import time
from dataclasses import dataclass
from typing import Any

from .utils import log_info

_SENSITIVE_FIELD_PARTS = ("text", "transcript", "prompt", "clipboard")


@dataclass(frozen=True)
class AudioChunk:
    session_id: int
    index: int
    audio: Any
    is_final: bool
    captured_at: float
    enqueued_at: float


def emit_runtime_event(event: str, **fields: object) -> None:
    """Write one privacy-safe, machine-readable event to the normal app log."""
    for key in fields:
        lowered = key.lower()
        if any(part in lowered for part in _SENSITIVE_FIELD_PARTS):
            raise ValueError(f"Sensitive runtime telemetry field is forbidden: {key}")
    payload = {
        "event": event,
        "monotonic": round(time.monotonic(), 6),
        **fields,
    }
    log_info(
        "runtime_event "
        + json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str)
    )


def collect_process_metrics(child_pid: int | None = None) -> dict[str, int | float | None]:
    """Return best-effort RSS and system-memory metrics without affecting runtime."""
    metrics: dict[str, int | float | None] = {
        "parent_rss_mb": None,
        "child_rss_mb": None,
        "system_memory_percent": None,
    }
    try:
        import os

        import psutil
    except ImportError:
        return metrics

    try:
        metrics["parent_rss_mb"] = round(
            psutil.Process(os.getpid()).memory_info().rss / (1024 * 1024),
            2,
        )
        metrics["system_memory_percent"] = float(psutil.virtual_memory().percent)
        if child_pid:
            metrics["child_rss_mb"] = round(
                psutil.Process(child_pid).memory_info().rss / (1024 * 1024),
                2,
            )
    except (OSError, AttributeError, psutil.Error):
        pass
    return metrics
