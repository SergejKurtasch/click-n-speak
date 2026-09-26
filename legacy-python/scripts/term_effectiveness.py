"""Compute per-term hit-rate from dataset JSONL.

Usage:
    source venv/bin/activate && python scripts/term_effectiveness.py

Output columns:
  term        — vocabulary term
  in_raw      — times term appeared in raw Whisper output
  in_final    — times term appeared in user-confirmed final text
  help_ratio  — in_raw / in_final (≈1.0 → Whisper recognised it; <0.3 → user always adds it manually)
"""

import json
from collections import Counter
from pathlib import Path

DATASET = Path.home() / ".clicknspeak_dataset.jsonl"

if not DATASET.exists():
    print(f"Dataset not found: {DATASET}")
    raise SystemExit(1)

in_raw: Counter = Counter()
in_final: Counter = Counter()
total = 0
skipped = 0

for line in DATASET.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except json.JSONDecodeError:
        skipped += 1
        continue
    if "vocab_terms_in_raw" not in rec:
        skipped += 1
        continue
    total += 1
    in_raw.update(rec.get("vocab_terms_in_raw") or [])
    in_final.update(rec.get("vocab_terms_in_final") or [])

print(f"Records analysed: {total}  (skipped/legacy: {skipped})\n")

all_terms = set(in_raw) | set(in_final)
if not all_terms:
    print("No vocabulary hits recorded yet.")
    raise SystemExit(0)

print(f"{'term':<30} {'in_raw':>8} {'in_final':>10} {'help_ratio':>12}")
print("-" * 64)
for term, n_final in sorted(in_final.items(), key=lambda x: -x[1]):
    n_raw = in_raw.get(term, 0)
    ratio = n_raw / n_final if n_final else 0.0
    print(f"{term:<30} {n_raw:>8} {n_final:>10} {ratio:>12.1%}")
# Terms seen in raw but never in final (Whisper found them, user discarded)
raw_only = set(in_raw) - set(in_final)
if raw_only:
    print()
    print("Terms in raw only (user never kept them):")
    for term in sorted(raw_only):
        print(f"  {term}  ({in_raw[term]}×)")
