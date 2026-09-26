#!/usr/bin/env python3
"""Converts SVG icons to black-on-transparent PNG Template Images for macOS.
Template Images adapt automatically to dark/light mode when marked as templates.
Usage: python scripts/convert_icons_template.py
"""
import re
import subprocess
import sys
from pathlib import Path

try:
    import cairosvg
except ImportError:
    subprocess.run([sys.executable, "-m", "pip", "install", "cairosvg"], check=True)
    import cairosvg  # type: ignore

ROOT = Path(__file__).resolve().parent.parent
SRC_MENUBAR = ROOT / "design" / "icons" / "menubar"
SRC_MENU = ROOT / "design" / "icons" / "menu"
DST_MENUBAR = ROOT / "assets" / "icons" / "menubar"
DST_MENU = ROOT / "assets" / "icons" / "menu"


def _to_black(svg_content: str) -> str:
    """Replace all color values with black, preserving opacity for visual depth."""
    svg_content = svg_content.replace('fill="white"', 'fill="black"')
    svg_content = svg_content.replace('stroke="white"', 'stroke="black"')
    svg_content = svg_content.replace("fill: white", "fill: black")
    svg_content = svg_content.replace("stroke: white", "stroke: black")
    svg_content = re.sub(r'rgba\(255\s*,\s*255\s*,\s*255', 'rgba(0,0,0', svg_content)
    svg_content = svg_content.replace("currentColor", "black")
    svg_content = re.sub(r'fill="#[0-9A-Fa-f]{3,6}"', 'fill="black"', svg_content)
    svg_content = re.sub(r'stroke="#[0-9A-Fa-f]{3,6}"', 'stroke="black"', svg_content)
    return svg_content


for svg in sorted(SRC_MENUBAR.glob("*.svg")):
    content = _to_black(svg.read_text(encoding="utf-8"))
    out = DST_MENUBAR / f"{svg.stem}Template.png"
    cairosvg.svg2png(bytestring=content.encode(), write_to=str(out), output_width=44, output_height=44)
    print(f"✓ menubar/{svg.name} → {out.name}")

for svg in sorted(SRC_MENU.glob("*.svg")):
    content = _to_black(svg.read_text(encoding="utf-8"))
    out = DST_MENU / f"{svg.stem}Template.png"
    cairosvg.svg2png(bytestring=content.encode(), write_to=str(out), output_width=32, output_height=32)
    print(f"✓ menu/{svg.name} → {out.name}")

print("Done! Restart the app to see adaptive icons.")
