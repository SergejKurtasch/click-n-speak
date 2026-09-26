"""One-shot cleanup of corrections.json: remove self-replace pairs and hallucinations.

Run from repo root with activated venv:
    source venv/bin/activate && python scripts/clean_corrections.py [--dry-run]
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from src.correction_analyzer import _migrate_corrections_index_to_v3, _read_index
from src.utils import get_corrections_file_path, write_json_atomic


def main() -> None:
    parser = argparse.ArgumentParser(description="Clean corrections.json replacement pairs")
    parser.add_argument("--dry-run", action="store_true", help="Print stats without writing")
    parser.add_argument("--path", help="Explicit path to corrections.json (auto-detected otherwise)")
    args = parser.parse_args()

    path = Path(args.path) if args.path else get_corrections_file_path()
    if not path.exists():
        # Fallback: check Application Support (when running as dev without .app context)
        fallback = Path.home() / "Library" / "Application Support" / "Click-n-speak" / "corrections.json"
        if fallback.exists():
            path = fallback
    if not path.exists():
        print(f"corrections.json not found at {path}")
        return

    raw = json.loads(path.read_text(encoding="utf-8"))
    before = {
        bucket: len(raw.get("replacement_pairs", {}).get(bucket, []))
        for bucket in ("latin", "cyrillic")
    }

    migrated = _migrate_corrections_index_to_v3(dict(raw))

    after = {
        bucket: len(migrated.get("replacement_pairs", {}).get(bucket, []))
        for bucket in ("latin", "cyrillic")
    }

    print("=== Replacement pairs cleanup ===")
    for bucket in ("latin", "cyrillic"):
        removed = before[bucket] - after[bucket]
        print(f"  {bucket}: {before[bucket]} → {after[bucket]} ({removed} removed)")
    total_before = sum(before.values())
    total_after = sum(after.values())
    print(f"  TOTAL: {total_before} → {total_after} ({total_before - total_after} removed)")

    if args.dry_run:
        print("\n--dry-run: nothing written.")
        return

    write_json_atomic(path, migrated, indent=2)
    print(f"\nWritten: {path}")


if __name__ == "__main__":
    main()
