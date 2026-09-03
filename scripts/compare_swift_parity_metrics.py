"""Validate privacy-safe Swift candidate metrics against predeclared thresholds."""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
from pathlib import Path
from typing import Any

LOGGER = logging.getLogger("compare_swift_parity_metrics")


def load_object(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return value


def evaluate(
    candidate: dict[str, Any],
    threshold_document: dict[str, Any],
) -> tuple[list[dict[str, Any]], list[str]]:
    thresholds = threshold_document.get("thresholds")
    if not isinstance(thresholds, dict) or not thresholds:
        raise ValueError("Threshold document is missing thresholds")
    metrics = candidate.get("metrics")
    if not isinstance(metrics, dict):
        raise ValueError("Candidate document is missing metrics")

    results: list[dict[str, Any]] = []
    failures: list[str] = []
    for name, raw_policy in thresholds.items():
        if not isinstance(raw_policy, dict):
            raise ValueError(f"Invalid threshold policy: {name}")
        direction = raw_policy.get("direction")
        limit = raw_policy.get("value")
        value = metrics.get(name)
        if direction not in {"minimum", "maximum"} or not isinstance(limit, (int, float)):
            raise ValueError(f"Invalid threshold policy: {name}")
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            passed = False
            observed: float | None = None
        else:
            observed = float(value)
            passed = observed >= float(limit) if direction == "minimum" else observed <= float(limit)
        if not passed:
            failures.append(str(name))
        results.append(
            {
                "metric": name,
                "direction": direction,
                "threshold": float(limit),
                "observed": observed,
                "status": "passed" if passed else "failed",
            }
        )
    return results, failures


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
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument(
        "--thresholds",
        type=Path,
        default=Path("tests/parity/quality_thresholds.json"),
    )
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = parse_args()
    results, failures = evaluate(load_object(args.candidate), load_object(args.thresholds))
    output = {
        "schema_version": 1,
        "status": "passed" if not failures else "failed",
        "failures": failures,
        "results": results,
    }
    write_atomic(args.output, output)
    LOGGER.info("Metric acceptance %s: %s", output["status"], args.output)
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
