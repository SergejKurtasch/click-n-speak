"""Produce privacy-safe aggregate metrics from Codex rollout JSONL files."""

from __future__ import annotations

import argparse
import json
import logging
from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Iterable, Mapping

LOGGER = logging.getLogger(__name__)
REPO_ROOT = Path(__file__).resolve().parents[1]
CONTENT_BEARING_FIELDS = frozenset(
    {
        "arguments",
        "base_instructions",
        "command",
        "content",
        "context",
        "encrypted_content",
        "hook_context",
        "input",
        "last_agent_message",
        "message",
        "output",
        "prompt",
        "raw_content",
        "replacement_history",
        "result",
        "stdout",
        "summary",
        "summary_text",
        "text",
    }
)
TURN_KINDS = frozenset({"root", "subagent", "guardian"})
APPROVAL_EVENT_TYPES = frozenset({"approval", "approval_requested", "approval_resolved"})
APPROVAL_STATUSES = frozenset({"approved", "pending", "rejected", "required"})


@dataclass(frozen=True)
class SessionSummary:
    """Aggregate counters that deliberately exclude all session content."""

    window_start: str
    window_end: str
    logical_sessions: int
    root_turns: int
    subagent_turns: int
    guardian_turns: int
    compactions: int
    approval_events: int
    input_tokens: int
    missing_command_events: int
    model_effort_distribution: dict[str, dict[str, int]]


def _parse_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _is_in_window(timestamp: object, start: datetime, end: datetime) -> bool:
    parsed = _parse_timestamp(timestamp)
    return parsed is not None and start <= parsed < end


def _increment_turn(turn_kind: object, counters: dict[str, int]) -> None:
    if isinstance(turn_kind, str) and turn_kind in TURN_KINDS:
        counters[turn_kind] += 1


def _add_model_effort(payload: dict[str, Any], distribution: dict[str, dict[str, int]]) -> None:
    model = payload.get("model")
    effort = payload.get("effort")
    if isinstance(model, str) and isinstance(effort, str):
        distribution[model][effort] += 1


def _usage_input_tokens(usage: object) -> int | None:
    if not isinstance(usage, dict):
        return None
    tokens = usage.get("input_tokens")
    return tokens if isinstance(tokens, int) and tokens >= 0 else None


def _input_token_snapshots(payload: dict[str, Any]) -> tuple[int | None, int | None]:
    """Return a cumulative total or an older-schema last-turn fallback, never both."""
    if payload.get("type") != "token_count":
        return None, None
    info = payload.get("info")
    if not isinstance(info, dict):
        return None, None
    if "total_token_usage" in info:
        return _usage_input_tokens(info["total_token_usage"]), None
    return None, _usage_input_tokens(info.get("last_token_usage"))


def _is_approval(payload: dict[str, Any]) -> bool:
    return payload.get("type") in APPROVAL_EVENT_TYPES and payload.get("status") in APPROVAL_STATUSES


def _is_compaction(record_type: object, payload: dict[str, Any]) -> bool:
    if record_type == "compacted":
        return True
    item = payload.get("item")
    return (
        payload.get("type") == "item_completed" and isinstance(item, dict) and item.get("type") == "ContextCompaction"
    )


def summarize_rollouts(paths: Iterable[Path], start: datetime, end: datetime) -> SessionSummary:
    """Summarize allowed rollout metadata from JSONL files without retaining bodies."""
    normalized_start = start.astimezone(UTC) if start.tzinfo else start.replace(tzinfo=UTC)
    normalized_end = end.astimezone(UTC) if end.tzinfo else end.replace(tzinfo=UTC)
    if normalized_end <= normalized_start:
        raise ValueError("end must be after start")
    counters = {"root": 0, "subagent": 0, "guardian": 0}
    distribution: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    logical_sessions = 0
    compactions = 0
    approval_events = 0
    input_tokens = 0
    missing_command_events = 0

    for path in paths:
        session_in_window = False
        session_total_tokens: int | None = None
        session_legacy_tokens = 0
        try:
            with path.open("r", encoding="utf-8") as handle:
                for line in handle:
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        LOGGER.warning("Skipping malformed session record")
                        continue
                    if not isinstance(record, dict) or not _is_in_window(
                        record.get("timestamp"), normalized_start, normalized_end
                    ):
                        continue
                    session_in_window = True
                    payload = record.get("payload")
                    if not isinstance(payload, dict):
                        continue

                    record_type = record.get("type")
                    if record_type == "turn_context":
                        _add_model_effort(payload, distribution)
                    if payload.get("type") == "task_started":
                        _increment_turn(payload.get("collaboration_mode_kind"), counters)
                    if _is_compaction(record_type, payload):
                        compactions += 1
                    if _is_approval(payload):
                        approval_events += 1
                    total_snapshot, legacy_snapshot = _input_token_snapshots(payload)
                    if total_snapshot is not None:
                        session_total_tokens = max(session_total_tokens or 0, total_snapshot)
                    if legacy_snapshot is not None:
                        session_legacy_tokens = max(session_legacy_tokens, legacy_snapshot)
                    if payload.get("error_category") == "missing_command":
                        missing_command_events += 1
        except OSError:
            LOGGER.warning("Skipping unreadable session file")
            continue
        if session_in_window:
            logical_sessions += 1
            input_tokens += session_total_tokens if session_total_tokens is not None else session_legacy_tokens

    return SessionSummary(
        window_start=normalized_start.isoformat().replace("+00:00", "Z"),
        window_end=normalized_end.isoformat().replace("+00:00", "Z"),
        logical_sessions=logical_sessions,
        root_turns=counters["root"],
        subagent_turns=counters["subagent"],
        guardian_turns=counters["guardian"],
        compactions=compactions,
        approval_events=approval_events,
        input_tokens=input_tokens,
        missing_command_events=missing_command_events,
        model_effort_distribution={
            model: dict(sorted(efforts.items())) for model, efforts in sorted(distribution.items())
        },
    )


SUMMARY_FIELDS = frozenset(SessionSummary.__dataclass_fields__)
COUNTER_FIELDS = frozenset(
    {
        "logical_sessions",
        "root_turns",
        "subagent_turns",
        "guardian_turns",
        "compactions",
        "approval_events",
        "input_tokens",
        "missing_command_events",
    }
)


def _validated_summary(payload: Mapping[str, Any]) -> dict[str, Any]:
    if frozenset(payload) != SUMMARY_FIELDS:
        raise ValueError("Report does not match the aggregate session summary schema")
    for field in COUNTER_FIELDS:
        value = payload[field]
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValueError(f"Report field {field} must be a non-negative integer")
    for field in ("window_start", "window_end"):
        if _parse_timestamp(payload[field]) is None:
            raise ValueError(f"Report field {field} must be an ISO-8601 timestamp")
    if not isinstance(payload["model_effort_distribution"], dict):
        raise ValueError("model_effort_distribution must be an object")
    return dict(payload)


def _report_window(summary: Mapping[str, Any]) -> tuple[datetime, datetime]:
    start = _parse_timestamp(summary["window_start"])
    end = _parse_timestamp(summary["window_end"])
    assert start is not None and end is not None
    if end - start != timedelta(days=14):
        raise ValueError("Reports must each cover one non-overlapping 14-day UTC window")
    return start, end


def _reduction_percent(baseline: int, comparison: int) -> float | None:
    if baseline == 0:
        return None
    return round((baseline - comparison) / baseline * 100, 2)


def compare_14_day_reports(baseline: Mapping[str, Any], comparison: Mapping[str, Any]) -> dict[str, Any]:
    """Compare two non-overlapping aggregate reports without loading session content."""
    validated_baseline = _validated_summary(baseline)
    validated_comparison = _validated_summary(comparison)
    baseline_start, baseline_end = _report_window(validated_baseline)
    comparison_start, comparison_end = _report_window(validated_comparison)
    if max(baseline_start, comparison_start) < min(baseline_end, comparison_end):
        raise ValueError("Reports must each cover one non-overlapping 14-day UTC window")

    def per_root(summary: Mapping[str, Any], field: str) -> float | None:
        root_turns = summary["root_turns"]
        if root_turns == 0:
            return None
        return round(summary[field] / root_turns, 4)

    return {
        "baseline_window_start": validated_baseline["window_start"],
        "baseline_window_end": validated_baseline["window_end"],
        "comparison_window_start": validated_comparison["window_start"],
        "comparison_window_end": validated_comparison["window_end"],
        "baseline_approval_events": validated_baseline["approval_events"],
        "comparison_approval_events": validated_comparison["approval_events"],
        "approval_event_reduction_percent": _reduction_percent(
            validated_baseline["approval_events"], validated_comparison["approval_events"]
        ),
        "input_token_reduction_percent": _reduction_percent(
            validated_baseline["input_tokens"], validated_comparison["input_tokens"]
        ),
        "baseline_compactions_per_root_turn": per_root(validated_baseline, "compactions"),
        "comparison_compactions_per_root_turn": per_root(validated_comparison, "compactions"),
        "comparison_missing_command_events": validated_comparison["missing_command_events"],
    }


def _content_bearing_field_count(payload: object) -> int:
    if isinstance(payload, dict):
        return sum(
            int(key in CONTENT_BEARING_FIELDS) + _content_bearing_field_count(value) for key, value in payload.items()
        )
    if isinstance(payload, list):
        return sum(_content_bearing_field_count(value) for value in payload)
    return 0


def _session_paths(sessions_root: Path) -> list[Path]:
    if not sessions_root.exists():
        return []
    return sorted(sessions_root.rglob("*.jsonl"))


def _load_aggregate_report(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ValueError(f"Unable to read aggregate report: {path}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"Aggregate report is not valid JSON: {path}") from error
    if not isinstance(payload, dict):
        raise ValueError("Aggregate report must be an object")
    return _validated_summary(payload)


def _safe_output_path(path: Path) -> Path:
    resolved = path.resolve()
    if resolved.is_relative_to(REPO_ROOT):
        raise ValueError("--output must be outside the repository")
    return resolved


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sessions-root",
        type=Path,
        default=Path.home() / ".codex" / "sessions",
        help="Directory containing rollout JSONL files.",
    )
    parser.add_argument("--days", type=int, default=14, help="Number of trailing UTC days to include.")
    parser.add_argument("--output", type=Path, help="Optional JSON destination outside version control.")
    parser.add_argument(
        "--compare-reports",
        nargs=2,
        type=Path,
        metavar=("BASELINE", "COMPARISON"),
        help="Compare two existing non-overlapping 14-day aggregate reports.",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate the report schema without writing a report.",
    )
    return parser


def main() -> int:
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s: %(message)s")
    args = _build_parser().parse_args()
    if args.days <= 0:
        raise SystemExit("--days must be positive")
    if args.compare_reports and args.validate_only:
        raise SystemExit("--compare-reports cannot be combined with --validate-only")

    try:
        if args.compare_reports:
            baseline, comparison = args.compare_reports
            payload = compare_14_day_reports(_load_aggregate_report(baseline), _load_aggregate_report(comparison))
        else:
            end = datetime.now(UTC)
            start = end - timedelta(days=args.days)
            summary = summarize_rollouts(_session_paths(args.sessions_root), start, end)
            payload = asdict(summary)
    except ValueError as error:
        LOGGER.error("Session audit failed: %s", error)
        return 2
    content_bearing_fields = _content_bearing_field_count(payload)

    if args.validate_only:
        print(json.dumps({"content_bearing_fields": content_bearing_fields, "schema_valid": True}, sort_keys=True))
        return 0 if content_bearing_fields == 0 else 1
    if content_bearing_fields:
        raise SystemExit("Refusing to write a content-bearing report")

    serialized = json.dumps(payload, sort_keys=True, indent=2) + "\n"
    try:
        if args.output:
            _safe_output_path(args.output).write_text(serialized, encoding="utf-8")
        else:
            print(serialized, end="")
    except (OSError, ValueError) as error:
        LOGGER.error("Session audit failed: %s", error)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
