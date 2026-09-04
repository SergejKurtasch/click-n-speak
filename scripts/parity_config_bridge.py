"""Apply the real Python config migration/save path to a sanitized fixture."""

from __future__ import annotations

import argparse
import datetime as datetime_module
import json
import logging
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from src import utils  # noqa: E402

LOGGER = logging.getLogger("parity_config_bridge")
FIXED_NOW = datetime_module.datetime(
    2026,
    7,
    14,
    12,
    0,
    0,
    123456,
    tzinfo=datetime_module.timezone.utc,
)


class FixedDatetime(datetime_module.datetime):
    @classmethod
    def now(cls, tz: datetime_module.tzinfo | None = None) -> datetime_module.datetime:
        return FIXED_NOW.astimezone(tz) if tz else FIXED_NOW.replace(tzinfo=None)


def migrate(config: dict[str, Any]) -> dict[str, Any]:
    previous_datetime = utils.datetime
    previous_tokenizer_tried = utils._prompt_tokenizer_tried
    previous_tokenizer = utils._prompt_tokenizer
    try:
        utils._prompt_tokenizer_tried = True
        utils._prompt_tokenizer = None
        utils.datetime = FixedDatetime
        config = utils.migrate_config_to_v2(config)
        config = utils.migrate_config_to_v3(config)
        config = utils.migrate_config_to_v4(config)
        config = utils.migrate_config_to_v5(config)
        config = utils.migrate_config_to_v6(config)
        config = utils.migrate_config_to_v7(config)
        config = utils.migrate_config_to_v8(config)
        config = utils.migrate_config_to_v9(config)
        config = utils.migrate_config_to_v10(config)
        config = utils.normalize_ukrainian_lang_codes(config)
        config.setdefault("last_metrics_snapshot_ts", None)
        config.setdefault("notify_on_metrics", True)
        config.setdefault("last_metrics_notification_ts", None)
        return config
    finally:
        utils.datetime = previous_datetime
        utils._prompt_tokenizer_tried = previous_tokenizer_tried
        utils._prompt_tokenizer = previous_tokenizer


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mark-python-update", action="store_true")
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = parse_args()
    with args.input.open("r", encoding="utf-8") as handle:
        raw = json.load(handle)
    if not isinstance(raw, dict):
        raise ValueError("Config fixture must be a JSON object")
    migrated = migrate(raw)
    if args.mark_python_update:
        migrated["parity_python_update"] = True
    utils.write_json_atomic(args.output, migrated, indent=4)
    LOGGER.info("Migrated sanitized config fixture to schema %s", migrated.get("schema_version"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
