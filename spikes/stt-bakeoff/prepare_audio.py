"""Normalize golden-set recordings to 16 kHz mono WAV for a fair engine comparison.

Reads any audio in golden/audio/ named <id>.<ext> (m4a/wav/caf/mp3/aac) and
writes golden/audio_16k/<id>.wav via /usr/bin/afconvert (Core Audio, no ffmpeg).
Validates that every id in manifest.jsonl has exactly one recording and reports
durations so obviously broken takes surface before scoring.

Run from repo root:  python spikes/stt-bakeoff/prepare_audio.py
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wav_io import duration_seconds  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
GOLDEN = HERE / "golden"
SRC = GOLDEN / "audio"
DST = GOLDEN / "audio_16k"
MANIFEST = GOLDEN / "manifest.jsonl"

AUDIO_EXTS = (".m4a", ".wav", ".caf", ".mp3", ".aac", ".aiff", ".aif")


def load_ids() -> list[str]:
    return [json.loads(line)["id"] for line in MANIFEST.read_text(encoding="utf-8").splitlines() if line.strip()]


def find_source(pid: str) -> Path | None:
    for ext in AUDIO_EXTS:
        for candidate in (SRC / f"{pid}{ext}", SRC / f"{pid}{ext.upper()}"):
            if candidate.exists():
                return candidate
    # Tolerate Voice Memos suffixes like "001 2.m4a" or "001-1.m4a".
    matches = sorted(p for p in SRC.glob(f"{pid}*") if p.suffix.lower() in AUDIO_EXTS)
    return matches[0] if matches else None


def convert(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(src), str(dst)],
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"afconvert failed for {src.name}: {result.stderr.decode(errors='replace').strip()}")


def main() -> int:
    if not SRC.exists():
        print(f"Missing source folder: {SRC}", file=sys.stderr)
        return 1

    ids = load_ids()
    missing: list[str] = []
    converted: list[tuple[str, float]] = []

    for pid in ids:
        src = find_source(pid)
        if src is None:
            missing.append(pid)
            continue
        dst = DST / f"{pid}.wav"
        convert(src, dst)
        converted.append((pid, duration_seconds(dst)))

    print(f"converted {len(converted)}/{len(ids)} recordings → {DST}")
    if converted:
        durs = sorted(d for _, d in converted)
        total = sum(d for _, d in converted)
        print(f"duration: min={durs[0]:.1f}s median={durs[len(durs)//2]:.1f}s max={durs[-1]:.1f}s total={total/60:.1f}min")
        suspicious = [(p, d) for p, d in converted if d < 0.8 or d > 30]
        if suspicious:
            print("\nSuspicious takes (very short / very long) — check these:")
            for p, d in suspicious:
                print(f"  {p}: {d:.1f}s")
    if missing:
        print(f"\nMISSING {len(missing)} recordings: {', '.join(missing)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
