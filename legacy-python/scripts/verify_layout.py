"""Verify the legacy application tree without importing runtime dependencies."""

from __future__ import annotations

import sys
from pathlib import Path


LEGACY_ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    required_paths = (
        "main.py",
        "src",
        "tests",
        "assets",
        "locales",
        "pyproject.toml",
        "requirements.txt",
        "setup.py",
        "config.example.json",
        "scripts/build.sh",
    )
    missing = [path for path in required_paths if not (LEGACY_ROOT / path).exists()]
    if missing:
        print(f"Missing legacy application paths: {', '.join(missing)}", file=sys.stderr)
        return 1

    forbidden = ("../swift-app", "../../swift-app")
    scan_roots = (LEGACY_ROOT / "main.py", LEGACY_ROOT / "src", LEGACY_ROOT / "scripts")
    for path in scan_roots:
        files = (path,) if path.is_file() else (item for item in path.rglob("*") if item.is_file())
        for file in files:
            if file == Path(__file__):
                continue
            if file.suffix not in {".py", ".sh", ".c"}:
                continue
            text = file.read_text(encoding="utf-8")
            if any(value in text for value in forbidden):
                print(f"Forbidden sibling application reference in {file}", file=sys.stderr)
                return 1

    print(f"Legacy Python layout is self-contained: {LEGACY_ROOT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
