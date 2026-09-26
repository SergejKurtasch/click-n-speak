#!/usr/bin/env python3
"""Validate and run the opt-in native realtime latency benchmark matrix."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import math
import os
import statistics
import struct
import subprocess
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

LOGGER = logging.getLogger("benchmark_realtime_latency")
REPO_ROOT = Path(__file__).resolve().parents[1]
RUNNER = REPO_ROOT / "scripts" / "swift_benchmark_latency.sh"
BENCHMARK_PROMPT_FIXTURE = (
    REPO_ROOT
    / "Packages"
    / "CNSTranscription"
    / "Tests"
    / "CNSTranscriptionTests"
    / "Fixtures"
    / "golden_thresholds.json"
)
BENCHMARK_SCOPE = "full_pipeline_audiochunker_vad_session"
MODEL_CHOICE_ELIGIBLE = False
MODEL_CHOICE_BLOCKER = "Task 5 model selection requires successful full-pipeline local-Qwen B/C results"
QUALITY_GATE_LIMITS: Mapping[str, float] = {
    "overall_wer": 0.048,
    "ru_wer": 0.050,
    "en_wer": 0.079,
    "mixed_wer": 0.077,
    "short_command_accuracy": 0.70,
    "term_recall": 0.83,
}
MAXIMUM_TURBO_WER_REGRESSION = 0.01


class ValidationError(ValueError):
    """An input or benchmark result did not satisfy the reproducibility contract."""


@dataclass(frozen=True)
class ModelSpec:
    model_id: str
    file_name: str
    size: int
    sha256: str


@dataclass(frozen=True)
class ModelArtifact:
    model_id: str
    path: Path
    sha256: str


@dataclass(frozen=True)
class CorpusArtifact:
    root: Path
    manifest_path: Path
    audio_paths: tuple[Path, ...]
    sample_counts: tuple[int, ...]
    row_count: int
    sha256: str
    rows: tuple[CorpusRow, ...]


@dataclass(frozen=True)
class CorpusRow:
    sample_id: str
    language: str
    bucket: str
    text: str
    terms: tuple[str, ...]
    audio_name: str
    sample_count: int
    reference_word_count: int


@dataclass(frozen=True)
class BenchmarkPrompt:
    initial_prompt: str
    user_terms: Mapping[str, tuple[str, ...]]
    sha256: str


@dataclass(frozen=True)
class BenchmarkCase:
    case_id: str
    model_id: str
    language_mode: str
    pipeline_profile: str
    max_speech_duration: float
    description: str


@dataclass(frozen=True)
class RunObservation:
    case: BenchmarkCase
    sample_id: str
    repetition: int
    temperature: str


@dataclass(frozen=True)
class BenchmarkBatch:
    """Observations that share one live Whisper and optional Qwen runtime."""

    case: BenchmarkCase
    observations: tuple[RunObservation, ...]


# These values mirror CNSCore.ModelRegistry. Keeping the accepted filenames,
# sizes, and hashes here lets the Python orchestrator reject unpinned local
# files before it launches Swift; it never searches nested paths or downloads.
MODEL_REGISTRY: Mapping[str, ModelSpec] = {
    "whisper-large-v3": ModelSpec(
        "whisper-large-v3",
        "ggml-large-v3.bin",
        3_095_033_483,
        "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
    ),
    "whisper-large-v3-turbo": ModelSpec(
        "whisper-large-v3-turbo",
        "ggml-large-v3-turbo.bin",
        1_624_555_275,
        "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
    ),
}

CONTROL_SAMPLE_IDS = frozenset({"001", "004", "005", "009", "026", "029", "034", "038", "039", "040", "041", "042"})
CORPUS_BUCKETS = frozenset({"short", "medium", "long"})

NUMBER_WORDS: Mapping[str, int] = {
    "один": 1,
    "одна": 1,
    "одного": 1,
    "два": 2,
    "две": 2,
    "двух": 2,
    "три": 3,
    "трех": 3,
    "четыре": 4,
    "четырех": 4,
    "пять": 5,
    "пяти": 5,
    "шесть": 6,
    "шести": 6,
    "семь": 7,
    "семи": 7,
    "восемь": 8,
    "восьми": 8,
    "девять": 9,
    "девяти": 9,
    "десять": 10,
    "десяти": 10,
    "двадцать": 20,
    "тридцать": 30,
    "сорок": 40,
    "пятьдесят": 50,
    "сто": 100,
    "двести": 200,
    "триста": 300,
    "четыреста": 400,
    "пятьсот": 500,
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "twenty": 20,
    "thirty": 30,
    "fifty": 50,
    "hundred": 100,
}

RESULT_SCHEMA_KEYS = frozenset(
    {
        "schema_version",
        "adapter",
        "case_id",
        "model_id",
        "model_checksum",
        "editor_model_checksum",
        "corpus_checksum",
        "prompt_checksum",
        "sample_id",
        "sample_count",
        "emitted_sample_count",
        "transcribed_sample_count",
        "chunk_count",
        "chunk_sample_counts",
        "language",
        "bucket",
        "repetition",
        "repetitions",
        "temperature",
        "language_mode",
        "pipeline_profile",
        "max_speech_duration",
        "capture_duration_seconds",
        "decode_duration_seconds",
        "stop_to_preview_seconds",
        "stop_to_popup_seconds",
        "total_duration_seconds",
        "outcome",
        "editor_outcome",
        "editor_duration_seconds",
        "detected_language",
        "word_errors",
        "reference_word_count",
        "term_hits",
        "term_total",
    }
)


def build_matrix(
    d_model_id: str | None,
    *,
    include_qwen: bool = False,
) -> tuple[BenchmarkCase, ...]:
    """Return the real AudioChunker/VAD/SessionController benchmark matrix.

    A is accepted only as a separately validated external baseline. B and C
    always exercise the same capture and session path; the optional local-Qwen
    pass keeps editor latency separate from the STT-only diagnostic.
    """
    cases = [
        BenchmarkCase(
            "B",
            "whisper-large-v3",
            "bilingual",
            "full_pipeline_stt_only",
            8.0,
            "Large v3 full pipeline with the editor disabled",
        ),
        BenchmarkCase(
            "C",
            "whisper-large-v3-turbo",
            "bilingual",
            "full_pipeline_stt_only",
            8.0,
            "Turbo full pipeline with the editor disabled",
        ),
    ]
    if include_qwen:
        cases.extend(
            [
                BenchmarkCase(
                    "B",
                    "whisper-large-v3",
                    "bilingual",
                    "full_pipeline_local_qwen",
                    8.0,
                    "Large v3 full pipeline with local Qwen",
                ),
                BenchmarkCase(
                    "C",
                    "whisper-large-v3-turbo",
                    "bilingual",
                    "full_pipeline_local_qwen",
                    8.0,
                    "Turbo full pipeline with local Qwen",
                ),
            ]
        )
    if d_model_id is not None:
        if d_model_id not in {"whisper-large-v3", "whisper-large-v3-turbo"}:
            raise ValidationError("--d-model-id must select the measured B or C model")
        cases.append(
            BenchmarkCase(
                "D",
                d_model_id,
                "bilingual",
                "full_pipeline_stt_only",
                6.0,
                "Six-second maximum-chunk full-pipeline STT pass",
            )
        )
        if include_qwen:
            cases.append(
                BenchmarkCase(
                    "D",
                    d_model_id,
                    "bilingual",
                    "full_pipeline_local_qwen",
                    6.0,
                    "Six-second maximum-chunk full pipeline with local Qwen",
                )
            )
    return tuple(cases)


def normalize_text(text: str) -> tuple[str, ...]:
    """Apply the exact benchmark reference normalization used by Swift."""
    lowered = text.lower().replace("ё", "е").replace("-", " ")
    tokens = "".join(character if character.isalnum() or character == "_" else " " for character in lowered).split()
    normalized: list[str] = []
    index = 0
    while index < len(tokens):
        if tokens[index] not in NUMBER_WORDS:
            normalized.append(tokens[index])
            index += 1
            continue
        total = 0
        while index < len(tokens) and tokens[index] in NUMBER_WORDS:
            total += NUMBER_WORDS[tokens[index]]
            index += 1
        normalized.append(str(total))
    return tuple(normalized)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_model(
    model_directory: Path,
    model_id: str,
    *,
    registry: Mapping[str, ModelSpec] = MODEL_REGISTRY,
) -> ModelArtifact:
    """Resolve one exact registry artifact and verify its size and SHA-256."""
    try:
        spec = registry[model_id]
    except KeyError as error:
        raise ValidationError(f"unknown ModelRegistry id: {model_id}") from error
    path = model_directory / spec.file_name
    if not path.is_file():
        raise ValidationError(f"missing ModelRegistry artifact: {path}")
    actual_size = path.stat().st_size
    if actual_size != spec.size:
        raise ValidationError(f"model size mismatch for {model_id}: expected {spec.size}, found {actual_size}")
    checksum = sha256_file(path)
    if checksum != spec.sha256:
        raise ValidationError(f"model checksum mismatch for {model_id}: expected {spec.sha256}, found {checksum}")
    return ModelArtifact(model_id=model_id, path=path, sha256=checksum)


def validate_qwen_snapshot(snapshot_directory: Path) -> str:
    """Fingerprint the exact local Qwen snapshot used by a full editor pass."""
    required = ("config.json", "tokenizer.json", "model.safetensors")
    paths = [snapshot_directory / name for name in required]
    if not snapshot_directory.is_dir() or any(not path.is_file() for path in paths):
        raise ValidationError("Qwen snapshot must contain config.json, tokenizer.json, and model.safetensors")
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.name.encode("utf-8"))
        digest.update(bytes.fromhex(sha256_file(path)))
    return digest.hexdigest()


def validate_benchmark_prompt(path: Path = BENCHMARK_PROMPT_FIXTURE) -> BenchmarkPrompt:
    """Load the pinned bilingual prompt and vocabulary used by the benchmark."""
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"invalid benchmark dictionary: {error}") from error
    if not isinstance(payload, Mapping):
        raise ValidationError("benchmark dictionary must be an object")
    initial_prompt = payload.get("initial_prompt")
    raw_terms = payload.get("benchmark_user_terms")
    if not isinstance(initial_prompt, str) or not initial_prompt.strip() or not isinstance(raw_terms, Mapping):
        raise ValidationError("benchmark dictionary requires initial_prompt and benchmark_user_terms")
    terms: dict[str, tuple[str, ...]] = {}
    for language in ("ru", "en"):
        values = raw_terms.get(language)
        if (
            not isinstance(values, list)
            or not values
            or any(not isinstance(value, str) or not value.strip() for value in values)
        ):
            raise ValidationError(f"benchmark dictionary requires nonempty {language} terms")
        normalized = tuple(value.strip() for value in values)
        if len({value.casefold() for value in normalized}) != len(normalized):
            raise ValidationError(f"benchmark dictionary has duplicate {language} terms")
        terms[language] = normalized
    return BenchmarkPrompt(
        initial_prompt=initial_prompt.strip(),
        user_terms=terms,
        sha256=sha256_file(path),
    )


def _wav_sample_count(path: Path) -> int:
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValidationError(f"corpus audio is not RIFF/WAVE: {path}")
    if int.from_bytes(data[4:8], "little") != len(data) - 8:
        raise ValidationError(f"corpus WAV has an inconsistent RIFF size: {path}")
    position = 12
    fmt: bytes | None = None
    data_size: int | None = None
    while position + 8 <= len(data):
        chunk_id = data[position : position + 4]
        size = int.from_bytes(data[position + 4 : position + 8], "little")
        start = position + 8
        padded_end = start + size + (size & 1)
        if padded_end > len(data):
            raise ValidationError(f"truncated WAV chunk in {path}")
        if chunk_id == b"fmt ":
            if fmt is not None:
                raise ValidationError(f"corpus WAV has duplicate fmt chunks: {path}")
            fmt = data[start : start + size]
        elif chunk_id == b"data":
            if data_size is not None:
                raise ValidationError(f"corpus WAV has duplicate data chunks: {path}")
            data_size = size
        position = padded_end
    if fmt is None or len(fmt) < 16 or data_size is None:
        raise ValidationError(f"corpus WAV is missing fmt/data chunks: {path}")
    format_tag, channels, sample_rate, byte_rate, block_align, bits = struct.unpack_from("<HHIIHH", fmt)
    is_pcm = format_tag == 1
    if format_tag == 0xFFFE and len(fmt) >= 40:
        extension_size, valid_bits = struct.unpack_from("<HH", fmt, 16)
        pcm_subformat = bytes.fromhex("0100000000001000800000aa00389b71")
        is_pcm = extension_size >= 22 and valid_bits == 16 and fmt[24:40] == pcm_subformat
    if (
        not is_pcm
        or channels != 1
        or sample_rate != 16_000
        or bits != 16
        or block_align != 2
        or byte_rate != sample_rate * block_align
        or data_size % block_align != 0
    ):
        raise ValidationError(f"corpus WAV must be 16 kHz mono PCM16: {path}")
    sample_count = data_size // block_align
    if sample_count == 0:
        raise ValidationError(f"corpus WAV contains no PCM samples: {path}")
    return sample_count


def validate_corpus(corpus_root: Path, *, expected_rows: int | None = None) -> CorpusArtifact:
    """Validate JSONL rows and exact 16 kHz PCM files, then fingerprint the corpus."""
    manifest_path = corpus_root / "manifest.jsonl"
    audio_root = corpus_root / "audio_16k"
    if not manifest_path.is_file():
        raise ValidationError(f"missing corpus manifest: {manifest_path}")
    if not audio_root.is_dir():
        raise ValidationError(f"missing corpus audio directory: {audio_root}")
    try:
        rows = [json.loads(line) for line in manifest_path.read_text(encoding="utf-8").splitlines() if line]
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"invalid corpus manifest: {manifest_path}: {error}") from error
    if not rows:
        raise ValidationError("corpus manifest is empty")
    if expected_rows is not None and len(rows) != expected_rows:
        raise ValidationError(f"expected {expected_rows} corpus rows, found {len(rows)}")

    required_fields = {"id", "lang", "bucket", "text", "terms", "audio"}
    seen_ids: set[str] = set()
    audio_paths: list[Path] = []
    sample_counts: list[int] = []
    corpus_rows: list[CorpusRow] = []
    fingerprint = hashlib.sha256(manifest_path.read_bytes())
    for row in rows:
        if not isinstance(row, dict):
            raise ValidationError("each corpus manifest row must be an object")
        missing_fields = sorted(required_fields - row.keys())
        if missing_fields:
            raise ValidationError(f"corpus row is missing required fields: {', '.join(missing_fields)}")
        sample_id = row.get("id")
        audio_name = row.get("audio")
        language = row.get("lang")
        bucket = row.get("bucket")
        text = row.get("text")
        terms = row.get("terms")
        if not isinstance(sample_id, str) or not sample_id or sample_id in seen_ids:
            raise ValidationError(f"invalid or duplicate corpus id: {sample_id!r}")
        if not isinstance(audio_name, str) or Path(audio_name).name != audio_name:
            raise ValidationError(f"invalid corpus audio path for {sample_id}: {audio_name!r}")
        if language not in {"ru", "en", "ru+en"}:
            raise ValidationError(f"unsupported corpus language for {sample_id}: {language!r}")
        if bucket not in CORPUS_BUCKETS:
            raise ValidationError(f"unsupported corpus bucket for {sample_id}: {bucket!r}")
        if not isinstance(text, str) or not text.strip():
            raise ValidationError(f"invalid corpus text for {sample_id}")
        reference_word_count = len(normalize_text(text))
        if reference_word_count == 0:
            raise ValidationError(f"corpus text normalizes to no words for {sample_id}")
        if not isinstance(terms, list) or any(
            not isinstance(term, str)
            or not term.strip()
            or not any(character.isalnum() or character == "_" for character in term)
            for term in terms
        ):
            raise ValidationError(f"invalid corpus terms for {sample_id}")
        audio_path = audio_root / audio_name
        if not audio_path.is_file():
            raise ValidationError(f"missing corpus audio for {sample_id}: {audio_path}")
        seen_ids.add(sample_id)
        audio_paths.append(audio_path)
        sample_count = _wav_sample_count(audio_path)
        sample_counts.append(sample_count)
        corpus_rows.append(
            CorpusRow(
                sample_id=sample_id,
                language=language,
                bucket=bucket,
                text=text,
                terms=tuple(terms),
                audio_name=audio_name,
                sample_count=sample_count,
                reference_word_count=reference_word_count,
            )
        )
        fingerprint.update(audio_name.encode("utf-8"))
        fingerprint.update(bytes.fromhex(sha256_file(audio_path)))
    return CorpusArtifact(
        root=corpus_root,
        manifest_path=manifest_path,
        audio_paths=tuple(audio_paths),
        sample_counts=tuple(sample_counts),
        row_count=len(rows),
        sha256=fingerprint.hexdigest(),
        rows=tuple(corpus_rows),
    )


def build_run_schedule(
    matrix: Sequence[BenchmarkCase],
    corpus: CorpusArtifact,
    repetitions: int,
    *,
    control_sample_ids: set[str] | frozenset[str] = CONTROL_SAMPLE_IDS,
) -> tuple[RunObservation, ...]:
    """Interleave cases for every cold corpus sample and warm control repeat."""
    if repetitions < 1:
        raise ValidationError("--repetitions must be at least 1")
    if not matrix:
        raise ValidationError("benchmark matrix is empty")
    corpus_ids = {row.sample_id for row in corpus.rows}
    missing_controls = sorted(set(control_sample_ids) - corpus_ids)
    if missing_controls:
        raise ValidationError(f"control sample IDs are absent from corpus: {', '.join(missing_controls)}")

    schedule: list[RunObservation] = []
    group_index = 0

    def append_group(sample_id: str, repetition: int, temperature: str) -> None:
        nonlocal group_index
        offset = group_index % len(matrix)
        cases = tuple(matrix[offset:]) + tuple(matrix[:offset])
        schedule.extend(
            RunObservation(
                case=case,
                sample_id=sample_id,
                repetition=repetition,
                temperature=temperature,
            )
            for case in cases
        )
        group_index += 1

    for index, row in enumerate(corpus.rows):
        append_group(row.sample_id, 0, "cold" if index == 0 else "warm")
    controls = [row.sample_id for row in corpus.rows if row.sample_id in control_sample_ids]
    for repetition in range(1, repetitions + 1):
        for sample_id in controls:
            append_group(sample_id, repetition, "warm")
    return tuple(schedule)


def build_run_batches(
    matrix: Sequence[BenchmarkCase],
    corpus: CorpusArtifact,
    repetitions: int,
    *,
    control_sample_ids: set[str] | frozenset[str] = CONTROL_SAMPLE_IDS,
) -> tuple[BenchmarkBatch, ...]:
    """Group each case into one process so the scheduled warm rows stay warm."""
    schedule = build_run_schedule(
        matrix,
        corpus,
        repetitions,
        control_sample_ids=control_sample_ids,
    )
    batches: list[BenchmarkBatch] = []
    for case in matrix:
        observations = tuple(item for item in schedule if item.case == case)
        if not observations:
            raise ValidationError(f"benchmark case {case.case_id} has no observations")
        if observations[0].temperature != "cold" or any(item.temperature != "warm" for item in observations[1:]):
            raise ValidationError(f"benchmark case {case.case_id} has an invalid warmup schedule")
        batches.append(BenchmarkBatch(case=case, observations=observations))
    return tuple(batches)


def write_batch_schedule(batch: BenchmarkBatch, path: Path) -> None:
    """Write the observation order consumed by one persistent Swift benchmark process."""
    payload = {
        "schema_version": 1,
        "observations": [
            {
                "sample_id": observation.sample_id,
                "repetition": observation.repetition,
                "temperature": observation.temperature,
            }
            for observation in batch.observations
        ],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _require_int(row: Mapping[str, Any], key: str, *, minimum: int = 0) -> int:
    value = row.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValidationError(f"result field {key} must be an integer >= {minimum}")
    return value


def _require_finite_number(row: Mapping[str, Any], key: str) -> float:
    value = row.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValidationError(f"result field {key} must be a finite number")
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise ValidationError(f"result field {key} must be a finite nonnegative number")
    return number


def validate_result_rows(
    rows: Sequence[Mapping[str, Any]],
    *,
    matrix: Sequence[BenchmarkCase],
    artifacts: Mapping[str, ModelArtifact],
    corpus: CorpusArtifact,
    repetitions: int,
    prompt_checksum: str,
    qwen_checksum: str | None = None,
    control_sample_ids: set[str] | frozenset[str] = CONTROL_SAMPLE_IDS,
) -> None:
    """Validate every JSONL row against the exact scheduled observation set."""
    schedule = build_run_schedule(
        matrix,
        corpus,
        repetitions,
        control_sample_ids=control_sample_ids,
    )
    if len(rows) != len(schedule):
        raise ValidationError(f"expected {len(schedule)} result rows, found {len(rows)}")
    expected = {
        (item.case.case_id, item.case.pipeline_profile, item.repetition, item.sample_id): item for item in schedule
    }
    corpus_by_id = {row.sample_id: row for row in corpus.rows}
    seen: set[tuple[str, str, int, str]] = set()

    for index, row in enumerate(rows, start=1):
        if not isinstance(row, Mapping):
            raise ValidationError(f"result row {index} must be an object")
        keys = set(row)
        if keys != RESULT_SCHEMA_KEYS:
            missing = sorted(RESULT_SCHEMA_KEYS - keys)
            extra = sorted(keys - RESULT_SCHEMA_KEYS)
            raise ValidationError(f"result row {index} schema mismatch; missing={missing}, extra={extra}")
        if (
            isinstance(row["schema_version"], bool)
            or not isinstance(row["schema_version"], int)
            or row["schema_version"] != 5
        ):
            raise ValidationError(f"result row {index} has unsupported schema_version")
        if row["adapter"] != "audiochunker_vad_session":
            raise ValidationError(f"result row {index} has inconsistent adapter")
        case_id = row["case_id"]
        sample_id = row["sample_id"]
        repetition = _require_int(row, "repetition")
        if not isinstance(case_id, str) or not isinstance(sample_id, str):
            raise ValidationError(f"result row {index} has invalid case/sample identity")
        pipeline_profile = row["pipeline_profile"]
        if not isinstance(pipeline_profile, str):
            raise ValidationError(f"result row {index} has invalid pipeline_profile")
        identity = (case_id, pipeline_profile, repetition, sample_id)
        if identity in seen:
            raise ValidationError(f"duplicate result row identity: {identity}")
        seen.add(identity)
        observation = expected.get(identity)
        if observation is None:
            raise ValidationError(f"unexpected result row identity: {identity}")
        case = observation.case
        corpus_row = corpus_by_id[sample_id]
        artifact = artifacts[case.model_id]
        expected_metadata: Mapping[str, Any] = {
            "case_id": case.case_id,
            "model_id": case.model_id,
            "model_checksum": artifact.sha256,
            "corpus_checksum": corpus.sha256,
            "prompt_checksum": prompt_checksum,
            "sample_id": corpus_row.sample_id,
            "sample_count": corpus_row.sample_count,
            "language": corpus_row.language,
            "bucket": corpus_row.bucket,
            "repetition": observation.repetition,
            "repetitions": repetitions,
            "temperature": observation.temperature,
            "language_mode": case.language_mode,
            "pipeline_profile": case.pipeline_profile,
            "max_speech_duration": case.max_speech_duration,
            "editor_model_checksum": (qwen_checksum if case.pipeline_profile == "full_pipeline_local_qwen" else None),
        }
        for key, expected_value in expected_metadata.items():
            if row[key] != expected_value:
                raise ValidationError(
                    f"result row {index} has inconsistent {key}: expected {expected_value!r}, found {row[key]!r}"
                )
        if _require_int(row, "sample_count", minimum=1) != corpus_row.sample_count:
            raise ValidationError(f"result row {index} has inconsistent sample_count")
        emitted_samples = _require_int(row, "emitted_sample_count")
        transcribed_samples = _require_int(row, "transcribed_sample_count")
        chunk_count = _require_int(row, "chunk_count", minimum=1)
        chunk_sample_counts = row["chunk_sample_counts"]
        if not isinstance(chunk_sample_counts, list):
            raise ValidationError(f"result row {index} has invalid chunk_sample_counts")
        if len(chunk_sample_counts) != chunk_count:
            raise ValidationError(f"result row {index} has inconsistent chunk_count")
        if any(isinstance(count, bool) or not isinstance(count, int) or count <= 0 for count in chunk_sample_counts):
            raise ValidationError(f"result row {index} has invalid chunk_sample_counts")
        if sum(chunk_sample_counts) != transcribed_samples:
            raise ValidationError(f"result row {index} lost or duplicated chunk samples")
        if emitted_samples == 0 or emitted_samples > corpus_row.sample_count:
            raise ValidationError(f"result row {index} has inconsistent emitted_sample_count")
        if transcribed_samples != emitted_samples:
            raise ValidationError(f"result row {index} lost or duplicated samples between capture and STT")
        if _require_int(row, "repetitions", minimum=1) != repetitions:
            raise ValidationError(f"result row {index} has inconsistent repetitions")
        reference_words = _require_int(row, "reference_word_count", minimum=1)
        if reference_words != corpus_row.reference_word_count:
            raise ValidationError(
                f"result row {index} has inconsistent reference_word_count: "
                f"expected {corpus_row.reference_word_count}, found {reference_words}"
            )
        word_errors = _require_int(row, "word_errors")
        term_hits = _require_int(row, "term_hits")
        term_total = _require_int(row, "term_total")
        if term_total != len(corpus_row.terms) or term_hits > term_total:
            raise ValidationError(f"result row {index} has inconsistent term counts")
        if word_errors > reference_words + _require_int(row, "sample_count"):
            raise ValidationError(f"result row {index} has implausible word_errors")
        capture = _require_finite_number(row, "capture_duration_seconds")
        _require_finite_number(row, "decode_duration_seconds")
        stop_to_preview = _require_finite_number(row, "stop_to_preview_seconds")
        stop_to_popup = _require_finite_number(row, "stop_to_popup_seconds")
        total = _require_finite_number(row, "total_duration_seconds")
        expected_capture = corpus_row.sample_count / 16_000
        if not math.isclose(capture, expected_capture, rel_tol=0, abs_tol=1e-9):
            raise ValidationError(f"result row {index} has inconsistent capture_duration_seconds")
        if stop_to_popup + 1e-9 < stop_to_preview:
            raise ValidationError(f"result row {index} has preview after popup")
        if total + 1e-9 < capture + stop_to_preview:
            raise ValidationError(f"result row {index} has inconsistent total_duration_seconds")
        outcome = row["outcome"]
        if not isinstance(outcome, str) or not (
            outcome in {"success", "no_speech", "timed_out", "aborted"}
            or outcome.startswith("guarded_")
            or outcome.startswith("failed_")
        ):
            raise ValidationError(f"result row {index} has invalid outcome")
        if not isinstance(row["detected_language"], str):
            raise ValidationError(f"result row {index} has invalid detected_language")
        editor_outcome = row["editor_outcome"]
        if editor_outcome not in {
            "ok",
            "unchanged",
            "timeout",
            "skipped",
            "error",
            "disabled",
            "memory_pressure",
        }:
            raise ValidationError(f"result row {index} has invalid editor_outcome")
        editor_duration = row["editor_duration_seconds"]
        if case.pipeline_profile == "full_pipeline_stt_only":
            if editor_outcome != "skipped" or editor_duration is not None:
                raise ValidationError(f"result row {index} has editor data in an STT-only pass")
        elif editor_duration is None:
            raise ValidationError(f"result row {index} is missing local-Qwen timing")
        else:
            _require_finite_number(row, "editor_duration_seconds")

    missing = sorted(expected.keys() - seen)
    if missing:
        raise ValidationError(f"missing result row identities: {missing}")


def _percentile(values: Sequence[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int((len(ordered) * fraction) + 0.999999) - 1))
    return ordered[index]


def aggregate_rows(
    rows: Sequence[Mapping[str, Any]], *, expected_case_ids: set[str]
) -> dict[str, dict[str, dict[str, Any]]]:
    """Aggregate latency distributions without hiding absent matrix results."""
    present = {str(row.get("case_id")) for row in rows}
    missing = sorted(expected_case_ids - present)
    if missing:
        raise ValidationError(f"missing benchmark results for cases: {', '.join(missing)}")
    summary: dict[str, dict[str, dict[str, Any]]] = {}
    for case_id in sorted(expected_case_ids):
        summary[case_id] = {}
        for temperature in ("cold", "warm"):
            selected = [row for row in rows if row.get("case_id") == case_id and row.get("temperature") == temperature]
            if not selected:
                raise ValidationError(f"missing {temperature} results for case: {case_id}")
            try:
                durations = [
                    float(
                        row["stop_to_preview_seconds"]
                        if "stop_to_preview_seconds" in row
                        else row["stop_to_text_seconds"]
                    )
                    for row in selected
                ]
                outcomes = Counter(str(row["outcome"]) for row in selected)
            except (KeyError, TypeError, ValueError) as error:
                raise ValidationError(f"malformed benchmark row for case {case_id}") from error
            if any(duration < 0 for duration in durations):
                raise ValidationError(f"negative duration in case {case_id}")
            summary[case_id][temperature] = {
                "n": len(durations),
                "median_seconds": statistics.median(durations),
                "p95_seconds": _percentile(durations, 0.95),
                "max_seconds": max(durations),
                "outcomes": dict(sorted(outcomes.items())),
            }
    return summary


def matrix_result_key(case: BenchmarkCase) -> str:
    """Keep STT-only and local-Qwen observations separate in summaries."""
    return f"{case.case_id}:{case.pipeline_profile}"


def aggregate_matrix_rows(
    rows: Sequence[Mapping[str, Any]], *, matrix: Sequence[BenchmarkCase]
) -> dict[str, dict[str, dict[str, Any]]]:
    transformed = [
        {
            **row,
            "case_id": f"{row.get('case_id')}:{row.get('pipeline_profile')}",
        }
        for row in rows
    ]
    return aggregate_rows(
        transformed,
        expected_case_ids={matrix_result_key(case) for case in matrix},
    )


def aggregate_quality(rows: Sequence[Mapping[str, Any]], *, expected_case_ids: set[str]) -> dict[str, dict[str, Any]]:
    """Aggregate transcript errors from each case's one complete corpus pass."""
    quality: dict[str, dict[str, Any]] = {}
    for case_id in sorted(expected_case_ids):
        selected = [row for row in rows if row.get("case_id") == case_id and row.get("repetition") == 0]
        if not selected:
            raise ValidationError(f"missing full-corpus quality results for case: {case_id}")
        totals_by_language: dict[str, list[int]] = {}
        total_errors = 0
        total_words = 0
        short_errors = 0
        short_words = 0
        term_hits = 0
        term_total = 0
        try:
            for row in selected:
                language = str(row["language"])
                errors = int(row["word_errors"])
                words = int(row["reference_word_count"])
                hits = int(row["term_hits"])
                terms = int(row["term_total"])
                if min(errors, words, hits, terms) < 0 or words == 0 or hits > terms:
                    raise ValueError("invalid quality count")
                totals = totals_by_language.setdefault(language, [0, 0])
                totals[0] += errors
                totals[1] += words
                total_errors += errors
                total_words += words
                term_hits += hits
                term_total += terms
                if row.get("bucket") == "short":
                    short_errors += errors
                    short_words += words
        except (KeyError, TypeError, ValueError) as error:
            raise ValidationError(f"malformed quality row for case {case_id}") from error
        quality[case_id] = {
            "sample_count": len(selected),
            "overall_wer": total_errors / total_words,
            "wer_by_language": {
                language: errors / words for language, (errors, words) in sorted(totals_by_language.items())
            },
            "short_command_accuracy": (1 - (short_errors / short_words) if short_words else None),
            "term_recall": term_hits / term_total if term_total else None,
        }
    return quality


def aggregate_matrix_quality(
    rows: Sequence[Mapping[str, Any]], *, matrix: Sequence[BenchmarkCase]
) -> dict[str, dict[str, Any]]:
    quality: dict[str, dict[str, Any]] = {}
    for case in matrix:
        key = matrix_result_key(case)
        selected = [
            {**row, "case_id": key}
            for row in rows
            if row.get("case_id") == case.case_id and row.get("pipeline_profile") == case.pipeline_profile
        ]
        quality.update(aggregate_quality(selected, expected_case_ids={key}))
    return quality


def _has_usable_benchmark_outcome(outcome: object) -> bool:
    """Accept a completed decode or a deliberately filtered empty tail.

    Guarded tails have already passed through the same AudioChunker and
    SessionController path. They carry no transcript text, while the row's
    sample accounting and quality score still expose any lost speech. They
    are therefore distinct from a timeout, abort, or backend failure.
    """
    return outcome == "success" or (isinstance(outcome, str) and outcome.startswith("guarded_"))


def model_choice_eligibility(
    rows: Sequence[Mapping[str, Any]], *, matrix: Sequence[BenchmarkCase]
) -> tuple[bool, str | None]:
    required = [
        case for case in matrix if case.case_id in {"B", "C"} and case.pipeline_profile == "full_pipeline_local_qwen"
    ]
    if {case.case_id for case in required} != {"B", "C"}:
        return False, "full-pipeline local-Qwen B/C results were not requested"
    for case in required:
        selected = [
            row
            for row in rows
            if row.get("case_id") == case.case_id and row.get("pipeline_profile") == case.pipeline_profile
        ]
        if not selected:
            return False, f"missing successful full-pipeline local-Qwen results for {case.case_id}"
        failed_outcomes = sorted(
            {str(row.get("outcome")) for row in selected if not _has_usable_benchmark_outcome(row.get("outcome"))}
        )
        if failed_outcomes:
            return False, (
                f"missing successful full-pipeline local-Qwen results for {case.case_id}: "
                f"{', '.join(failed_outcomes)}"
            )
        statuses = {row.get("editor_outcome") for row in selected}
        if statuses & {"timeout", "error", "disabled", "memory_pressure"}:
            return False, f"local-Qwen full-pipeline results for {case.case_id} contain {sorted(statuses)!r}"
        if not statuses & {"ok", "unchanged"}:
            return False, f"missing successful full-pipeline local-Qwen cleanup for {case.case_id}"

    try:
        quality = aggregate_matrix_quality(rows, matrix=required)
    except ValidationError as error:
        return False, f"cannot validate local-Qwen quality gates: {error}"

    for case in required:
        key = matrix_result_key(case)
        blocker = quality_gate_blocker(case.case_id, quality[key])
        if blocker is not None:
            return False, blocker

    large = quality[matrix_result_key(next(case for case in required if case.case_id == "B"))]
    turbo = quality[matrix_result_key(next(case for case in required if case.case_id == "C"))]
    large_wer = float(large["overall_wer"])
    turbo_wer = float(turbo["overall_wer"])
    if turbo_wer > large_wer + MAXIMUM_TURBO_WER_REGRESSION:
        return False, (
            "quality gate failed for C: overall WER regressed by more than "
            f"{MAXIMUM_TURBO_WER_REGRESSION:.3f} relative to B"
        )
    for metric in ("short_command_accuracy", "term_recall"):
        if float(turbo[metric]) + 1e-12 < float(large[metric]):
            return False, f"quality gate failed for C: {metric} is lower than B"
    return True, None


def quality_gate_blocker(case_id: str, quality: Mapping[str, Any]) -> str | None:
    """Return the first Task 5 quality-gate violation for one pipeline case."""
    try:
        overall = float(quality["overall_wer"])
        by_language = quality["wer_by_language"]
        if not isinstance(by_language, Mapping):
            raise TypeError("wer_by_language")
        russian = float(by_language["ru"])
        english = float(by_language["en"])
        mixed = float(by_language["ru+en"])
        short_accuracy = float(quality["short_command_accuracy"])
        term_recall = float(quality["term_recall"])
    except (KeyError, TypeError, ValueError):
        return f"quality gate failed for {case_id}: incomplete corpus quality metrics"

    checks = (
        ("overall WER", overall, QUALITY_GATE_LIMITS["overall_wer"], "maximum"),
        ("Russian WER", russian, QUALITY_GATE_LIMITS["ru_wer"], "maximum"),
        ("English WER", english, QUALITY_GATE_LIMITS["en_wer"], "maximum"),
        ("mixed-language WER", mixed, QUALITY_GATE_LIMITS["mixed_wer"], "maximum"),
        (
            "short-command accuracy",
            short_accuracy,
            QUALITY_GATE_LIMITS["short_command_accuracy"],
            "minimum",
        ),
        ("term recall", term_recall, QUALITY_GATE_LIMITS["term_recall"], "minimum"),
    )
    for label, observed, threshold, direction in checks:
        if direction == "maximum" and observed > threshold:
            return f"quality gate failed for {case_id}: {label} {observed:.3f} exceeds {threshold:.3f}"
        if direction == "minimum" and observed < threshold:
            return f"quality gate failed for {case_id}: {label} {observed:.3f} is below {threshold:.3f}"
    return None


def validate_external_baseline(
    path: Path,
    *,
    comparison_contract: Mapping[str, str],
) -> Mapping[str, Any]:
    """Validate an externally captured pre-change A artifact before comparison."""
    try:
        artifact = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"invalid external baseline: {error}") from error
    if not isinstance(artifact, Mapping):
        raise ValidationError("external baseline must be an object")
    required = {
        "schema_version": 1,
        "artifact_type": "clicknspeak_latency_baseline",
        "case_id": "A",
        "benchmark_scope": BENCHMARK_SCOPE,
    }
    for key, expected in required.items():
        if artifact.get(key) != expected:
            if key == "benchmark_scope":
                raise ValidationError("external baseline must use the full-pipeline benchmark scope")
            raise ValidationError(f"external baseline requires {key}={expected!r}")
    revision = artifact.get("implementation_revision")
    fingerprint = artifact.get("implementation_fingerprint")
    if not isinstance(revision, str) or not revision:
        raise ValidationError("external baseline is missing implementation_revision")
    if not isinstance(fingerprint, str) or len(fingerprint) != 64:
        raise ValidationError("external baseline has invalid implementation_fingerprint")
    contract = artifact.get("comparison_contract")
    if not isinstance(contract, Mapping) or any(
        contract.get(key) != value for key, value in comparison_contract.items()
    ):
        raise ValidationError("external baseline comparison contract does not match this run")
    latency = artifact.get("latency")
    if not isinstance(latency, Mapping):
        raise ValidationError("external baseline is missing latency metrics")
    for metric in ("stop_to_preview_seconds", "stop_to_popup_seconds"):
        values = latency.get(metric)
        if not isinstance(values, Mapping):
            raise ValidationError(f"external baseline is missing {metric}")
        n = values.get("n")
        if isinstance(n, bool) or not isinstance(n, int) or n < 1:
            raise ValidationError(f"external baseline has invalid {metric}.n")
        for field in ("median_seconds", "p95_seconds"):
            value = values.get(field)
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(float(value))
                or value < 0
            ):
                raise ValidationError(f"external baseline has invalid {metric}.{field}")
    return artifact


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-directory", required=True, type=Path)
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--repetitions", required=True, type=int)
    parser.add_argument(
        "--qwen-model-directory",
        type=Path,
        help="run the separate full-pipeline local-Qwen B/C pass from this snapshot",
    )
    parser.add_argument(
        "--baseline-results",
        type=Path,
        help="validated external full-pipeline A artifact; omitted means A is reported as not_run",
    )
    parser.add_argument(
        "--d-model-id",
        choices=("whisper-large-v3", "whisper-large-v3-turbo"),
        help="run D with a model chosen by separate full-pipeline B/C evidence",
    )
    return parser.parse_args(argv)


def _run_batch(
    batch: BenchmarkBatch,
    artifact: ModelArtifact,
    corpus: CorpusArtifact,
    prompt: BenchmarkPrompt,
    output_path: Path,
    schedule_path: Path,
    repetitions: int,
    qwen_model_directory: Path | None,
    qwen_checksum: str | None,
) -> None:
    environment = os.environ.copy()
    environment.update(
        {
            "CNS_LATENCY_BENCHMARKS": "1",
            "CNS_WHISPER_MODEL": str(artifact.path),
            "CNS_WHISPER_MODEL_ID": batch.case.model_id,
            "CNS_STT_GOLDEN_DIR": str(corpus.root),
            "CNS_BENCHMARK_OUTPUT": str(output_path),
            "CNS_BENCHMARK_INITIAL_PROMPT": prompt.initial_prompt,
            "CNS_BENCHMARK_USER_TERMS_JSON": json.dumps(
                {language: list(terms) for language, terms in prompt.user_terms.items()},
                ensure_ascii=False,
                separators=(",", ":"),
            ),
            "CNS_BENCHMARK_PROMPT_SHA256": prompt.sha256,
            "CNS_BENCHMARK_CASE_ID": batch.case.case_id,
            "CNS_BENCHMARK_LANGUAGE_MODE": batch.case.language_mode,
            "CNS_BENCHMARK_PIPELINE_PROFILE": batch.case.pipeline_profile,
            "CNS_BENCHMARK_MAX_SPEECH_DURATION": str(batch.case.max_speech_duration),
            "CNS_BENCHMARK_REPETITIONS": str(repetitions),
            "CNS_BENCHMARK_SCHEDULE": str(schedule_path),
            "CNS_BENCHMARK_MODEL_SHA256": artifact.sha256,
            "CNS_BENCHMARK_CORPUS_SHA256": corpus.sha256,
        }
    )
    if batch.case.pipeline_profile == "full_pipeline_local_qwen":
        if qwen_model_directory is None or qwen_checksum is None:
            raise ValidationError("local-Qwen case requires a validated Qwen snapshot")
        environment["CNS_QWEN_MODEL_DIR"] = str(qwen_model_directory)
        environment["CNS_BENCHMARK_QWEN_SHA256"] = qwen_checksum
    LOGGER.info(
        "running case %s %s batch (%d observations)",
        batch.case.case_id,
        batch.case.pipeline_profile,
        len(batch.observations),
    )
    subprocess.run(["bash", str(RUNNER)], cwd=REPO_ROOT, env=environment, check=True)


def run(args: argparse.Namespace) -> Path:
    if args.repetitions < 1:
        raise ValidationError("--repetitions must be at least 1")
    qwen_model_directory = args.qwen_model_directory.resolve() if args.qwen_model_directory else None
    qwen_checksum = validate_qwen_snapshot(qwen_model_directory) if qwen_model_directory else None
    prompt = validate_benchmark_prompt()
    matrix = build_matrix(args.d_model_id, include_qwen=qwen_model_directory is not None)
    model_directory = args.model_directory.resolve()
    corpus = validate_corpus(args.corpus.resolve(), expected_rows=42)
    model_ids = tuple(dict.fromkeys(case.model_id for case in matrix))
    artifacts = {model_id: validate_model(model_directory, model_id) for model_id in model_ids}

    output_directory = args.output_directory.resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    raw_path = output_directory / "realtime-latency.jsonl"
    raw_path.write_text("", encoding="utf-8")
    batches = build_run_batches(matrix, corpus, args.repetitions)
    schedule_directory = output_directory / "schedules"
    schedule_directory.mkdir(exist_ok=True)
    for index, batch in enumerate(batches, start=1):
        schedule_path = schedule_directory / (f"{index:02d}-{batch.case.case_id}-{batch.case.pipeline_profile}.json")
        write_batch_schedule(batch, schedule_path)
        _run_batch(
            batch,
            artifacts[batch.case.model_id],
            corpus,
            prompt,
            raw_path,
            schedule_path,
            args.repetitions,
            qwen_model_directory,
            qwen_checksum,
        )

    try:
        rows = [json.loads(line) for line in raw_path.read_text(encoding="utf-8").splitlines() if line]
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"invalid benchmark output: {error}") from error
    validate_result_rows(
        rows,
        matrix=matrix,
        artifacts=artifacts,
        corpus=corpus,
        repetitions=args.repetitions,
        prompt_checksum=prompt.sha256,
        qwen_checksum=qwen_checksum,
    )
    comparison_contract = {
        "corpus_sha256": corpus.sha256,
        "adapter": "audiochunker_vad_session",
        "language_mode": "bilingual",
    }
    baseline = (
        validate_external_baseline(args.baseline_results.resolve(), comparison_contract=comparison_contract)
        if args.baseline_results
        else None
    )
    eligible, blocker = model_choice_eligibility(rows, matrix=matrix)
    summary = {
        "schema_version": 1,
        "benchmark_scope": BENCHMARK_SCOPE,
        "model_choice_eligible": eligible,
        "model_choice_blocker": blocker,
        "corpus_sha256": corpus.sha256,
        "prompt_checksum": prompt.sha256,
        "corpus_rows": corpus.row_count,
        "repetitions": args.repetitions,
        "matrix": [asdict(case) for case in matrix],
        "results": aggregate_matrix_rows(rows, matrix=matrix),
        "quality": aggregate_matrix_quality(rows, matrix=matrix),
        "baseline": (
            {"status": "validated", "artifact": baseline}
            if baseline is not None
            else {"status": "not_run", "reason": "no external full-pipeline A artifact was supplied"}
        ),
    }
    summary_path = output_directory / "realtime-latency-summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return summary_path


def main(argv: Sequence[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    args = parse_args(argv)
    try:
        summary_path = run(args)
    except (ValidationError, subprocess.CalledProcessError, OSError) as error:
        LOGGER.error("%s", error)
        return 2
    LOGGER.info("wrote benchmark summary to %s", summary_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
