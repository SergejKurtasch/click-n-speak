"""Generate expected config-migration outputs using the real Python migration
functions, for the Swift equivalence test (Phase 1.5).

Determinism controls so Swift can reproduce byte-for-byte:
- The v5 migration timestamp is pinned to FIXED_NOW (monkeypatch datetime).
- The prompt token counter is forced to the heuristic (len // 3) by disabling
  the mlx_whisper tokenizer, so build_initial_prompt matches Swift's
  HeuristicTokenCounter. (Token-accurate truncation is a Phase 2 concern.)

Run from repo root inside venv:
    python spikes/config_migration_check/generate_expected.py
"""
from __future__ import annotations

import datetime as _dt
import json
from pathlib import Path

import src.utils as utils

FIXED_NOW = _dt.datetime(2026, 7, 14, 12, 0, 0, 123456, tzinfo=_dt.timezone.utc)

HERE = Path(__file__).resolve().parent
INPUTS = HERE / "inputs"
EXPECTED = HERE.parent.parent / "Packages" / "CNSCore" / "Tests" / "CNSCoreTests" / "Fixtures" / "migration_expected"


class _FixedDatetime(_dt.datetime):
    @classmethod
    def now(cls, tz=None):  # type: ignore[override]
        return FIXED_NOW.astimezone(tz) if tz else FIXED_NOW.replace(tzinfo=None)


def _run_chain(data: dict) -> dict:
    data = utils.migrate_config_to_v2(data)
    data = utils.migrate_config_to_v3(data)
    data = utils.migrate_config_to_v4(data)
    data = utils.migrate_config_to_v5(data)
    data = utils.migrate_config_to_v6(data)
    data = utils.migrate_config_to_v7(data)
    data = utils.migrate_config_to_v8(data)
    data = utils.migrate_config_to_v9(data)
    data = utils.normalize_ukrainian_lang_codes(data)
    data.setdefault("last_metrics_snapshot_ts", None)
    data.setdefault("notify_on_metrics", True)
    data.setdefault("last_metrics_notification_ts", None)
    return data


def main() -> None:
    # Force heuristic token counting to match Swift's HeuristicTokenCounter.
    utils._prompt_tokenizer_tried = True
    utils._prompt_tokenizer = None
    # Pin the v5 timestamp.
    utils.datetime = _FixedDatetime  # type: ignore[attr-defined]

    EXPECTED.mkdir(parents=True, exist_ok=True)
    for input_path in sorted(INPUTS.glob("*.json")):
        data = json.loads(input_path.read_text(encoding="utf-8"))
        migrated = _run_chain(data)
        out_path = EXPECTED / input_path.name
        out_path.write_text(json.dumps(migrated, indent=4), encoding="utf-8")
        print(f"{input_path.name}: schema_version -> {migrated.get('schema_version')}")

    print(f"\nFixed now: {FIXED_NOW.isoformat()}")
    print(f"Wrote expected outputs to {EXPECTED}")


if __name__ == "__main__":
    main()
