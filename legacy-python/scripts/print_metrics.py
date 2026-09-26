#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path

from src.metrics import compute_metrics
from src.utils import (
    get_config_path,
    get_corrections_file_path,
    migrate_config_to_v2,
    migrate_config_to_v3,
    migrate_config_to_v4,
    migrate_config_to_v5,
    migrate_config_to_v6,
)


def _load_config(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    data = migrate_config_to_v2(data)
    data = migrate_config_to_v3(data)
    data = migrate_config_to_v4(data)
    data = migrate_config_to_v5(data)
    data = migrate_config_to_v6(data)
    return data


def main() -> None:
    config = _load_config(get_config_path())
    metrics = compute_metrics(
        dataset_path=Path.home() / ".clicknspeak_dataset.jsonl",
        corrections_path=get_corrections_file_path(),
        config=config,
        window_size=100,
    )
    print(json.dumps(metrics, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
