"""Score STT engine outputs against the golden set.

Computes word-error rate (insertions + deletions + substitutions over reference
length) on normalized text, broken down by language and length bucket, plus
term recall (how often dictionary terms survive transcription — the metric that
separates engines most on this workload).

No external deps: WER is a plain word-level Levenshtein.

Usage:
    python spikes/stt-bakeoff/score.py results_mlx.jsonl [results_whisperkit.jsonl ...]

Each results file is JSONL with at least: {"id": "007", "text": "...",
optionally "decode_s", "load_s"}.
"""
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "golden" / "manifest.jsonl"


# Spelled numbers → value, covering the forms used in the golden set (including
# oblique cases). Whisper freely renders spoken numbers as either digits or
# words, so both sides are canonicalised to digits before scoring; otherwise a
# pure formatting choice would count as a recognition error and could differ
# between engines, confounding the comparison.
_NUM_WORDS: dict[str, int] = {
    # ru units / oblique forms
    "один": 1, "одна": 1, "одного": 1, "два": 2, "две": 2, "двух": 2,
    "три": 3, "трех": 3, "четыре": 4, "четырех": 4, "пять": 5, "пяти": 5,
    "шесть": 6, "шести": 6, "семь": 7, "семи": 7, "восемь": 8, "восьми": 8,
    "девять": 9, "девяти": 9, "десять": 10, "десяти": 10,
    # ru tens / hundreds
    "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50,
    "сто": 100, "двести": 200, "триста": 300, "четыреста": 400, "пятьсот": 500,
    # en
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "twenty": 20, "thirty": 30, "fifty": 50, "hundred": 100,
}


def _canonicalize_numbers(tokens: list[str]) -> list[str]:
    """Collapse runs of spelled-number tokens into a single digit string."""
    out: list[str] = []
    i = 0
    while i < len(tokens):
        if tokens[i] in _NUM_WORDS:
            total = 0
            while i < len(tokens) and tokens[i] in _NUM_WORDS:
                total += _NUM_WORDS[tokens[i]]
                i += 1
            out.append(str(total))
        else:
            out.append(tokens[i])
            i += 1
    return out


def normalize(text: str) -> str:
    """Lowercase, ё→е, hyphens→spaces, drop punctuation, canonicalise numbers.

    Applied identically to reference and hypothesis.
    """
    t = text.lower().replace("ё", "е")
    t = t.replace("-", " ")
    t = re.sub(r"[^\w\s]", " ", t, flags=re.UNICODE)
    t = re.sub(r"\s+", " ", t).strip()
    return " ".join(_canonicalize_numbers(t.split()))


def levenshtein_words(ref: list[str], hyp: list[str]) -> int:
    """Edit distance over word sequences."""
    if not ref:
        return len(hyp)
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        curr = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            curr[j] = min(
                prev[j] + 1,        # deletion
                curr[j - 1] + 1,    # insertion
                prev[j - 1] + (r != h),  # substitution
            )
        prev = curr
    return prev[-1]


def load_manifest() -> dict[str, dict]:
    rows = {}
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            rows[row["id"]] = row
    return rows


def load_results(path: Path) -> dict[str, dict]:
    rows = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            row = json.loads(line)
            rows[row["id"]] = row
    return rows


def score_engine(manifest: dict[str, dict], results: dict[str, dict]) -> dict:
    per_group_err: dict[str, int] = defaultdict(int)
    per_group_len: dict[str, int] = defaultdict(int)
    term_hit = term_total = 0
    missed_terms: list[tuple[str, str]] = []
    worst: list[tuple[float, str, str, str]] = []
    decode_times: list[float] = []

    for pid, ref_row in manifest.items():
        hyp_row = results.get(pid)
        if hyp_row is None:
            continue
        # Normalize the reference here (not the precomputed text_norm) so any
        # normalization change applies symmetrically to both sides.
        ref = normalize(ref_row["text"]).split()
        hyp = normalize(hyp_row.get("text", "")).split()
        errors = levenshtein_words(ref, hyp)

        for group in ("ALL", f"lang:{ref_row['lang']}", f"bucket:{ref_row['bucket']}"):
            per_group_err[group] += errors
            per_group_len[group] += len(ref)

        wer = errors / max(1, len(ref))
        worst.append((wer, pid, ref_row["text"], hyp_row.get("text", "")))

        hyp_norm = normalize(hyp_row.get("text", ""))
        for term in ref_row.get("terms", []):
            term_total += 1
            if normalize(term) in hyp_norm:
                term_hit += 1
            else:
                missed_terms.append((pid, term))

        if isinstance(hyp_row.get("decode_s"), (int, float)):
            decode_times.append(float(hyp_row["decode_s"]))

    return {
        "wer": {g: per_group_err[g] / max(1, per_group_len[g]) for g in per_group_err},
        "covered": sum(1 for pid in manifest if pid in results),
        "total": len(manifest),
        "term_recall": (term_hit / term_total) if term_total else None,
        "term_hit": term_hit,
        "term_total": term_total,
        "missed_terms": missed_terms,
        "worst": sorted(worst, reverse=True)[:8],
        "decode_times": sorted(decode_times),
    }


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 1
    manifest = load_manifest()
    reports = {}
    for arg in argv[1:]:
        path = Path(arg)
        name = path.stem.replace("results_", "")
        reports[name] = score_engine(manifest, load_results(path))

    groups = ["ALL", "lang:ru", "lang:ru+en", "lang:en", "bucket:short", "bucket:medium", "bucket:long"]
    names = list(reports)

    print(f"\n{'WER (lower is better)':<24}" + "".join(f"{n:>16}" for n in names))
    print("-" * (24 + 16 * len(names)))
    for g in groups:
        row = f"{g:<24}"
        for n in names:
            wer = reports[n]["wer"].get(g)
            row += f"{wer*100:>15.1f}%" if wer is not None else f"{'—':>16}"
        print(row)

    print(f"\n{'Term recall':<24}" + "".join(f"{n:>16}" for n in names))
    print("-" * (24 + 16 * len(names)))
    row = f"{'terms kept':<24}"
    for n in names:
        r = reports[n]
        cell = f"{r['term_hit']}/{r['term_total']}" if r["term_total"] else "—"
        row += f"{cell:>16}"
    print(row)
    row = f"{'recall':<24}"
    for n in names:
        r = reports[n]
        cell = f"{r['term_recall']*100:.0f}%" if r["term_recall"] is not None else "—"
        row += f"{cell:>16}"
    print(row)

    print(f"\n{'Decode time (s)':<24}" + "".join(f"{n:>16}" for n in names))
    print("-" * (24 + 16 * len(names)))
    for label, pick in (("median", lambda d: d[len(d) // 2]), ("max", lambda d: d[-1])):
        row = f"{label:<24}"
        for n in names:
            d = reports[n]["decode_times"]
            row += f"{pick(d):>16.2f}" if d else f"{'—':>16}"
        print(row)

    for n in names:
        r = reports[n]
        print(f"\n=== {n}: coverage {r['covered']}/{r['total']} ===")
        if r["missed_terms"]:
            print("  missed terms:", ", ".join(f"{t}({pid})" for pid, t in r["missed_terms"][:15]))
        print("  worst phrases:")
        for wer, pid, ref, hyp in r["worst"][:5]:
            print(f"   {pid} WER={wer*100:.0f}%\n      ref: {ref}\n      hyp: {hyp}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
