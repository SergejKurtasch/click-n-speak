"""Run WhisperKit (CoreML / Apple Neural Engine) over the golden set.

Same initial_prompt and language hint as production. Files are grouped by
language so the model loads once per group (per-file invocation would measure
cold CoreML load, not the warm decode the app experiences). Timings come from
WhisperKit's own JSON report.

`--chunking-strategy none` is used so WhisperKit decodes each file whole, like
the mlx baseline; its built-in VAD chunking would otherwise add a second layer
of segmentation on top of our own chunker.

Usage (from repo root, inside venv):
    python spikes/stt-bakeoff/run_whisperkit.py [--model large-v3_turbo]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import src.utils as utils

HERE = Path(__file__).resolve().parent
GOLDEN = HERE / "golden"
AUDIO = GOLDEN / "audio_16k"
MANIFEST = GOLDEN / "manifest.jsonl"
BIN = HERE / "whisperkit-src" / ".build" / "release" / "whisperkit-cli"
MODEL_DIR = HERE / "models" / "whisperkit"


def load_config() -> dict:
    path = Path.home() / "Library/Application Support/Click-n-speak/config.json"
    if not path.exists():
        path = Path("config.json")
    return json.loads(path.read_text(encoding="utf-8"))


def run_group(files: list[Path], lang: str, prompt: str, model: str, report_dir: Path,
              compute_units: str = "cpuAndGPU") -> None:
    cmd = [
        str(BIN), "transcribe",
        "--model", model,
        "--download-model-path", str(MODEL_DIR),
        "--download-tokenizer-path", str(MODEL_DIR),
        # Default is cpuAndNeuralEngine, which hangs indefinitely on
        # large-v3_turbo on this machine (tiny works; ANE compile cache stays
        # empty). cpuAndGPU is the only configuration that completes.
        "--audio-encoder-compute-units", compute_units,
        "--text-decoder-compute-units", compute_units,
        "--language", lang,
        "--prompt", prompt,
        "--temperature", "0.0",
        "--no-speech-threshold", "0.5",
        "--compression-ratio-threshold", "2.0",
        "--without-timestamps",
        "--skip-special-tokens",
        "--chunking-strategy", "none",
        "--report", "--report-path", str(report_dir),
    ]
    for f in files:
        cmd += ["--audio-path", str(f)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stdout[-2000:], file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
        raise RuntimeError(f"whisperkit-cli failed for lang={lang}")


def parse_reports(report_dir: Path) -> dict[str, dict]:
    """Map audio id → {text, decode_s} from WhisperKit JSON reports."""
    out: dict[str, dict] = {}
    for path in report_dir.rglob("*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        # Report shape varies by version; find the audio file name and text.
        audio = data.get("audioFilePath") or data.get("audio_file") or path.stem
        pid = Path(str(audio)).stem
        text = data.get("text")
        if text is None:
            segments = data.get("segments") or []
            text = " ".join(s.get("text", "") for s in segments)
        timings = data.get("timings") or {}
        decode_s = (
            timings.get("fullPipeline")
            or timings.get("decodingLoop")
            or timings.get("totalDecodingLoops")
            or 0.0
        )
        out[pid] = {"text": " ".join(str(text).split()).strip(), "decode_s": round(float(decode_s), 3)}
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="large-v3_turbo")
    ap.add_argument("--out", default="results_whisperkit.jsonl")
    args = ap.parse_args()

    if not BIN.exists():
        print(f"whisperkit-cli not built: {BIN}", file=sys.stderr)
        return 1

    prompt = utils.build_initial_prompt(load_config())
    rows = [json.loads(l) for l in MANIFEST.read_text(encoding="utf-8").splitlines() if l.strip()]

    groups: dict[str, list[Path]] = {"ru": [], "en": []}
    for row in rows:
        wav = AUDIO / f"{row['id']}.wav"
        if wav.exists():
            groups["ru" if row["lang"].startswith("ru") else "en"].append(wav)

    report_root = Path(tempfile.mkdtemp(prefix="wk-report-"))
    try:
        for lang, files in groups.items():
            if not files:
                continue
            print(f"running {len(files)} files for language={lang} (model {args.model})…")
            run_group(files, lang, prompt, args.model, report_root)
        parsed = parse_reports(report_root)
        results = [{"id": row["id"], **parsed[row["id"]]} for row in rows if row["id"] in parsed]
    finally:
        shutil.rmtree(report_root, ignore_errors=True)

    out_path = HERE / args.out
    with out_path.open("w", encoding="utf-8") as f:
        for r in results:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {len(results)} results → {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
