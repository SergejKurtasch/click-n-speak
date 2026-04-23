#!/usr/bin/env python3
"""Converts SVG icons from design/ to PNG for rumps.
Usage: python scripts/convert_icons.py
"""
import subprocess
import sys
from pathlib import Path

try:
    import cairosvg
except ImportError:
    subprocess.run([sys.executable, "-m", "pip", "install", "cairosvg"], check=True)
    import cairosvg  # type: ignore

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "design" / "icons"
DST = ROOT / "assets" / "icons"

(DST / "menubar").mkdir(parents=True, exist_ok=True)
for svg in (SRC / "menubar").glob("*.svg"):
    out = DST / "menubar" / svg.with_suffix(".png").name
    cairosvg.svg2png(url=str(svg), write_to=str(out), output_width=44, output_height=44)
    print(f"✓ menubar/{svg.name} → {out.name}")

(DST / "menu").mkdir(parents=True, exist_ok=True)
for svg in (SRC / "menu").glob("*.svg"):
    out = DST / "menu" / svg.with_suffix(".png").name
    cairosvg.svg2png(url=str(svg), write_to=str(out), output_width=32, output_height=32)
    print(f"✓ menu/{svg.name} → {out.name}")

print("Done!")
