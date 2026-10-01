"""Run the CURRENT production engine (mlx-whisper large-v3-turbo) over the
golden set to establish the baseline the Swift candidates must match.

Uses the same initial_prompt the app builds from the user's real config, and the
same decode options as realtime chunks in transcriber.py, so the baseline
reflects production behaviour rather than an idealised run.

Run from repo root inside venv:
    python spikes/stt-bakeoff/run_mlx_baseline.py
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import mlx_whisper  # type: ignore

import src.utils as utils

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wav_io import read_pcm16_mono  # noqa: E402

HERE = Path(__file__).resolve().parent
GOLDEN = HERE / "golden"
AUDIO = GOLDEN / "audio_16k"
MANIFEST = GOLDEN / "manifest.jsonl"
OUT = HERE / "results_mlx.jsonl"

MODEL = "mlx-community/whisper-large-v3-turbo"
REALTIME_MAX_TOKENS = 180  # matches transcriber.REALTIME_MAX_TOKENS


def load_config() -> dict:
    path = Path.home() / "Library/Application Support/Click-n-speak/config.json"
    if not path.exists():
        path = Path("config.json")
    return json.loads(path.read_text(encoding="utf-8"))


def load_audio(path: Path):
    samples, _rate = read_pcm16_mono(path)
    return samples


def main() -> None:
    config = load_config()
    initial_prompt = utils.build_initial_prompt(config)
    print(f"initial_prompt ({len(initial_prompt)} chars): {initial_prompt[:160]}…")

    rows = [json.loads(l) for l in MANIFEST.read_text(encoding="utf-8").splitlines() if l.strip()]
    results = []

    for i, row in enumerate(rows, 1):
        wav = AUDIO / f"{row['id']}.wav"
        if not wav.exists():
            print(f"  skip {row['id']}: no audio")
            continue
        audio = load_audio(wav)

        # Mirror the production language hint: a single primary language is
        # forced; auto-detect otherwise.
        lang = "ru" if row["lang"].startswith("ru") else "en"

        start = time.time()
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=MODEL,
            initial_prompt=initial_prompt,
            language=lang,
            condition_on_previous_text=True,
            temperature=0.0,
            no_speech_threshold=0.5,
            compression_ratio_threshold=2.0,
        )
        decode_s = time.time() - start
        text = (result.get("text") or "").strip()
        results.append({
            "id": row["id"],
            "text": text,
            "decode_s": round(decode_s, 3),
            "detected_language": result.get("language", ""),
        })
        print(f"  [{i}/{len(rows)}] {row['id']} {decode_s:5.2f}s  {text[:70]}")

    with OUT.open("w", encoding="utf-8") as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"\nwrote {len(results)} results → {OUT}")


if __name__ == "__main__":
    main()
