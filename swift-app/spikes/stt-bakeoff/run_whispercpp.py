"""Run whisper.cpp (Metal) over the golden set.

Uses the same initial_prompt and language hint as production. Decode time comes
from whisper.cpp's own `whisper_print_timings` (total minus load), because the
CLI reloads the 1.6 GB model on every invocation — wall-clock would measure cold
load, not the warm decode the app actually experiences.

Usage (from repo root, inside venv):
    python spikes/stt-bakeoff/run_whispercpp.py [--beam 1] [--out results_whispercpp.jsonl]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import src.utils as utils

HERE = Path(__file__).resolve().parent
GOLDEN = HERE / "golden"
AUDIO = GOLDEN / "audio_16k"
MANIFEST = GOLDEN / "manifest.jsonl"
MODEL = HERE / "models" / "ggml-large-v3-turbo.bin"
BIN = "/opt/homebrew/bin/whisper-cli"

_TIMING_RE = re.compile(r"whisper_print_timings:\s+(\w[\w ]*?)\s+=\s+([\d.]+) ms")


def load_config() -> dict:
    path = Path.home() / "Library/Application Support/Click-n-speak/config.json"
    if not path.exists():
        path = Path("config.json")
    return json.loads(path.read_text(encoding="utf-8"))


def parse_timings(stderr: str) -> dict[str, float]:
    return {m.group(1).strip(): float(m.group(2)) for m in _TIMING_RE.finditer(stderr)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--beam", type=int, default=1,
                    help="beam size; 1 = greedy, matching the production mlx decode")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if not MODEL.exists():
        print(f"Model not found: {MODEL}", file=sys.stderr)
        return 1

    out_path = HERE / (args.out or f"results_whispercpp_bs{args.beam}.jsonl")
    initial_prompt = utils.build_initial_prompt(load_config())
    rows = [json.loads(l) for l in MANIFEST.read_text(encoding="utf-8").splitlines() if l.strip()]

    results = []
    for i, row in enumerate(rows, 1):
        wav = AUDIO / f"{row['id']}.wav"
        if not wav.exists():
            print(f"  skip {row['id']}: no audio")
            continue
        lang = "ru" if row["lang"].startswith("ru") else "en"

        proc = subprocess.run(
            [
                BIN, "-m", str(MODEL), "-f", str(wav),
                "-l", lang, "--prompt", initial_prompt,
                # -nt: no timestamps. `-np` is deliberately NOT passed: it would
                # suppress whisper_print_timings on stderr, which is our only
                # source of load-excluded decode time.
                "-nt",
                "-tp", "0.0",                 # temperature 0 (production)
                "-nth", "0.5",                # no-speech threshold (production strict)
                "-bs", str(args.beam),
                "-t", "8",
            ],
            # whisper-cli can emit stray non-UTF8 bytes in its progress output.
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if proc.returncode != 0:
            print(f"  {row['id']} FAILED: {proc.stderr.strip()[:200]}", file=sys.stderr)
            continue

        text = " ".join(proc.stdout.split()).strip()
        timings = parse_timings(proc.stderr)
        load_ms = timings.get("load time", 0.0)
        total_ms = timings.get("total time", 0.0)
        decode_s = max(0.0, (total_ms - load_ms)) / 1000.0

        results.append({
            "id": row["id"],
            "text": text,
            "decode_s": round(decode_s, 3),
            "load_s": round(load_ms / 1000.0, 3),
        })
        print(f"  [{i}/{len(rows)}] {row['id']} {decode_s:5.2f}s  {text[:70]}")

    with out_path.open("w", encoding="utf-8") as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"\nwrote {len(results)} results → {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
