from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import struct
import subprocess
import sys
import wave
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SWIFT_ROOT = REPO_ROOT
SCRIPT_PATH = SWIFT_ROOT / "scripts" / "benchmark_realtime_latency.py"


def load_benchmark_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("benchmark_realtime_latency", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


benchmark = load_benchmark_module()


def write_pcm_wav(path: Path, frames: int = 320) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(b"\x00\x00" * frames)


def make_corpus(tmp_path: Path, sample_ids: tuple[str, ...] = ("001", "002")) -> Any:
    audio_root = tmp_path / "audio_16k"
    audio_root.mkdir()
    lines = []
    for index, sample_id in enumerate(sample_ids):
        audio_name = f"{sample_id}.wav"
        write_pcm_wav(audio_root / audio_name, frames=320 + index)
        lines.append(
            json.dumps(
                {
                    "id": sample_id,
                    "lang": "ru" if index == 0 else "en",
                    "bucket": "short" if index == 0 else "medium",
                    "text": f"sample {sample_id}",
                    "terms": ["sample"],
                    "audio": audio_name,
                }
            )
        )
    (tmp_path / "manifest.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return benchmark.validate_corpus(tmp_path)


def make_artifacts(matrix: Any, tmp_path: Path) -> dict[str, Any]:
    return {
        model_id: benchmark.ModelArtifact(
            model_id=model_id,
            path=tmp_path / f"{model_id}.bin",
            sha256=("a" if model_id == "whisper-large-v3" else "b") * 64,
        )
        for model_id in {case.model_id for case in matrix}
    }


def make_result_row(
    case: Any,
    artifact: Any,
    corpus: Any,
    sample_id: str,
    repetition: int,
    temperature: str,
    repetitions: int,
) -> dict[str, Any]:
    corpus_row = next(row for row in corpus.rows if row.sample_id == sample_id)
    capture_duration = corpus_row.sample_count / 16_000
    return {
        "schema_version": 5,
        "adapter": "audiochunker_vad_session",
        "case_id": case.case_id,
        "model_id": case.model_id,
        "model_checksum": artifact.sha256,
        "editor_model_checksum": None,
        "corpus_checksum": corpus.sha256,
        "prompt_checksum": "p" * 64,
        "sample_id": sample_id,
        "sample_count": corpus_row.sample_count,
        "emitted_sample_count": corpus_row.sample_count,
        "transcribed_sample_count": corpus_row.sample_count,
        "chunk_count": 1,
        "chunk_sample_counts": [corpus_row.sample_count],
        "language": corpus_row.language,
        "bucket": corpus_row.bucket,
        "repetition": repetition,
        "repetitions": repetitions,
        "temperature": temperature,
        "language_mode": case.language_mode,
        "pipeline_profile": case.pipeline_profile,
        "max_speech_duration": case.max_speech_duration,
        "capture_duration_seconds": capture_duration,
        "decode_duration_seconds": 0.01,
        "stop_to_preview_seconds": 0.01,
        "stop_to_popup_seconds": 0.02,
        "total_duration_seconds": capture_duration + 0.01,
        "outcome": "success",
        "editor_outcome": "skipped",
        "editor_duration_seconds": None,
        "detected_language": corpus_row.language,
        "word_errors": 0,
        "reference_word_count": len(benchmark.normalize_text(corpus_row.text)),
        "term_hits": 1,
        "term_total": 1,
    }


def test_cli_requires_all_benchmark_inputs() -> None:
    result = subprocess.run(
        [sys.executable, str(SCRIPT_PATH)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 2
    for option in ("--model-directory", "--corpus", "--output-directory", "--repetitions"):
        assert option in result.stderr


def test_build_matrix_compares_current_large_and_turbo_without_fake_baseline() -> None:
    matrix = benchmark.build_matrix(d_model_id=None)

    assert [case.case_id for case in matrix] == ["B", "C"]
    assert [case.model_id for case in matrix] == [
        "whisper-large-v3",
        "whisper-large-v3-turbo",
    ]
    assert [case.language_mode for case in matrix] == ["bilingual", "bilingual"]
    assert [case.pipeline_profile for case in matrix] == ["full_pipeline_stt_only", "full_pipeline_stt_only"]
    assert [case.max_speech_duration for case in matrix] == [8.0, 8.0]
    assert benchmark.BENCHMARK_SCOPE == "full_pipeline_audiochunker_vad_session"
    assert benchmark.MODEL_CHOICE_ELIGIBLE is False
    assert "local-Qwen" in benchmark.MODEL_CHOICE_BLOCKER


def test_build_matrix_requires_explicit_measured_model_for_d() -> None:
    matrix = benchmark.build_matrix(d_model_id="whisper-large-v3")

    assert matrix[-1].case_id == "D"
    assert matrix[-1].model_id == "whisper-large-v3"
    assert matrix[-1].max_speech_duration == 6.0

    with pytest.raises(benchmark.ValidationError, match="--d-model-id"):
        benchmark.build_matrix(d_model_id="whisper-small")


def test_validate_model_uses_registry_filename_size_and_checksum(tmp_path: Path) -> None:
    payload = b"pinned local model"
    checksum = hashlib.sha256(payload).hexdigest()
    model_path = tmp_path / "model.bin"
    model_path.write_bytes(payload)
    registry = {
        "test-model": benchmark.ModelSpec(
            model_id="test-model",
            file_name="model.bin",
            size=len(payload),
            sha256=checksum,
        )
    }

    artifact = benchmark.validate_model(tmp_path, "test-model", registry=registry)

    assert artifact.path == model_path
    assert artifact.sha256 == checksum


@pytest.mark.parametrize("mutation", ["missing", "size", "checksum"])
def test_validate_model_rejects_absent_or_unpinned_artifact(tmp_path: Path, mutation: str) -> None:
    payload = b"model"
    expected = hashlib.sha256(payload).hexdigest()
    registry = {"test-model": benchmark.ModelSpec("test-model", "model.bin", len(payload), expected)}
    if mutation != "missing":
        (tmp_path / "model.bin").write_bytes(payload + (b"x" if mutation == "size" else b""))
    if mutation == "checksum":
        registry["test-model"] = benchmark.ModelSpec("test-model", "model.bin", len(payload), "0" * 64)

    with pytest.raises(benchmark.ValidationError):
        benchmark.validate_model(tmp_path, "test-model", registry=registry)


def test_validate_qwen_snapshot_requires_pinned_runtime_files(tmp_path: Path) -> None:
    for name, contents in {
        "config.json": b"{}",
        "tokenizer.json": b"{}",
        "model.safetensors": b"weights",
    }.items():
        (tmp_path / name).write_bytes(contents)

    checksum = benchmark.validate_qwen_snapshot(tmp_path)

    assert len(checksum) == 64
    (tmp_path / "tokenizer.json").unlink()
    with pytest.raises(benchmark.ValidationError, match="Qwen snapshot"):
        benchmark.validate_qwen_snapshot(tmp_path)


def test_validate_benchmark_prompt_requires_the_pinned_dictionary_contract(tmp_path: Path) -> None:
    path = tmp_path / "benchmark-profile.json"
    path.write_text(
        json.dumps(
            {
                "initial_prompt": "Russian and English technical speech.",
                "benchmark_user_terms": {
                    "ru": ["Whisper"],
                    "en": ["Whisper"],
                },
            }
        ),
        encoding="utf-8",
    )

    prompt = benchmark.validate_benchmark_prompt(path)

    assert prompt.initial_prompt == "Russian and English technical speech."
    assert prompt.user_terms == {"ru": ("Whisper",), "en": ("Whisper",)}
    assert len(prompt.sha256) == 64

    path.write_text(json.dumps({"initial_prompt": "missing terms"}), encoding="utf-8")
    with pytest.raises(benchmark.ValidationError, match="benchmark dictionary"):
        benchmark.validate_benchmark_prompt(path)


def test_validate_corpus_checks_manifest_audio_and_builds_stable_checksum(tmp_path: Path) -> None:
    audio_root = tmp_path / "audio_16k"
    audio_root.mkdir()
    write_pcm_wav(audio_root / "001.wav")
    manifest_line = {
        "id": "001",
        "lang": "ru",
        "bucket": "short",
        "text": "Тест.",
        "terms": [],
        "audio": "001.wav",
    }
    (tmp_path / "manifest.jsonl").write_text(json.dumps(manifest_line) + "\n", encoding="utf-8")

    corpus = benchmark.validate_corpus(tmp_path)

    assert corpus.row_count == 1
    assert corpus.audio_paths == (audio_root / "001.wav",)
    assert len(corpus.sha256) == 64
    assert corpus.sample_counts == (320,)


def test_validate_corpus_rejects_missing_audio(tmp_path: Path) -> None:
    (tmp_path / "audio_16k").mkdir()
    (tmp_path / "manifest.jsonl").write_text(
        json.dumps(
            {
                "id": "001",
                "lang": "ru",
                "bucket": "short",
                "text": "Тест.",
                "terms": [],
                "audio": "missing.wav",
            }
        )
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(benchmark.ValidationError, match="missing.wav"):
        benchmark.validate_corpus(tmp_path)


def test_validate_corpus_rejects_manifest_missing_swift_required_fields(tmp_path: Path) -> None:
    audio_root = tmp_path / "audio_16k"
    audio_root.mkdir()
    write_pcm_wav(audio_root / "001.wav")
    (tmp_path / "manifest.jsonl").write_text(
        json.dumps({"id": "001", "lang": "ru", "audio": "001.wav"}) + "\n",
        encoding="utf-8",
    )

    with pytest.raises(benchmark.ValidationError, match="missing required fields"):
        benchmark.validate_corpus(tmp_path)


def test_validate_corpus_rejects_bucket_outside_manifest_contract(tmp_path: Path) -> None:
    audio_root = tmp_path / "audio_16k"
    audio_root.mkdir()
    write_pcm_wav(audio_root / "001.wav")
    (tmp_path / "manifest.jsonl").write_text(
        json.dumps(
            {
                "id": "001",
                "lang": "ru",
                "bucket": "tiny",
                "text": "Тест.",
                "terms": [],
                "audio": "001.wav",
            }
        )
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(benchmark.ValidationError, match="unsupported corpus bucket"):
        benchmark.validate_corpus(tmp_path)


def test_validate_corpus_rejects_empty_pcm_data(tmp_path: Path) -> None:
    audio_root = tmp_path / "audio_16k"
    audio_root.mkdir()
    write_pcm_wav(audio_root / "001.wav", frames=0)
    (tmp_path / "manifest.jsonl").write_text(
        json.dumps(
            {
                "id": "001",
                "lang": "ru",
                "bucket": "short",
                "text": "Тест.",
                "terms": [],
                "audio": "001.wav",
            }
        )
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(benchmark.ValidationError, match="contains no PCM samples"):
        benchmark.validate_corpus(tmp_path)


def test_validate_corpus_rejects_float_wav(tmp_path: Path) -> None:
    audio_root = tmp_path / "audio_16k"
    audio_root.mkdir()
    audio_path = audio_root / "001.wav"
    write_pcm_wav(audio_path)
    data = bytearray(audio_path.read_bytes())
    struct.pack_into("<H", data, 20, 3)
    audio_path.write_bytes(data)
    (tmp_path / "manifest.jsonl").write_text(
        json.dumps(
            {
                "id": "001",
                "lang": "ru",
                "bucket": "short",
                "text": "Тест.",
                "terms": [],
                "audio": "001.wav",
            }
        )
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(benchmark.ValidationError, match="PCM16"):
        benchmark.validate_corpus(tmp_path)


def test_run_schedule_interleaves_cases_for_each_sample(tmp_path: Path) -> None:
    corpus = make_corpus(tmp_path)
    matrix = benchmark.build_matrix(d_model_id=None)

    schedule = benchmark.build_run_schedule(
        matrix,
        corpus,
        repetitions=1,
        control_sample_ids={"001"},
    )

    assert [(item.sample_id, item.case.case_id) for item in schedule] == [
        ("001", "B"),
        ("001", "C"),
        ("002", "C"),
        ("002", "B"),
        ("001", "B"),
        ("001", "C"),
    ]
    assert [item.temperature for item in schedule] == [
        "cold",
        "cold",
        "warm",
        "warm",
        "warm",
        "warm",
    ]


def test_run_batches_keep_one_process_alive_for_the_warm_observations(tmp_path: Path) -> None:
    corpus = make_corpus(tmp_path)
    matrix = benchmark.build_matrix(d_model_id=None)

    batches = benchmark.build_run_batches(
        matrix,
        corpus,
        repetitions=1,
        control_sample_ids={"001"},
    )

    assert [(batch.case.case_id, batch.case.pipeline_profile) for batch in batches] == [
        ("B", "full_pipeline_stt_only"),
        ("C", "full_pipeline_stt_only"),
    ]
    assert [(item.sample_id, item.repetition, item.temperature) for item in batches[0].observations] == [
        ("001", 0, "cold"),
        ("002", 0, "warm"),
        ("001", 1, "warm"),
    ]
    assert [(item.sample_id, item.repetition, item.temperature) for item in batches[1].observations] == [
        ("001", 0, "cold"),
        ("002", 0, "warm"),
        ("001", 1, "warm"),
    ]


def test_run_batch_invokes_one_runner_with_a_serialized_schedule(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    corpus = make_corpus(tmp_path)
    matrix = benchmark.build_matrix(d_model_id=None)
    artifacts = make_artifacts(matrix, tmp_path)
    batch = benchmark.build_run_batches(
        matrix,
        corpus,
        repetitions=1,
        control_sample_ids={"001"},
    )[0]
    prompt = benchmark.BenchmarkPrompt(
        initial_prompt="Russian and English technical speech.",
        user_terms={"ru": ("Whisper",), "en": ("Whisper",)},
        sha256="p" * 64,
    )
    output_path = tmp_path / "results.jsonl"
    output_path.touch()
    schedule_path = tmp_path / "batch.json"
    benchmark.write_batch_schedule(batch, schedule_path)
    calls: list[dict[str, Any]] = []

    def fake_run(command: list[str], **kwargs: Any) -> None:
        calls.append({"command": command, **kwargs})

    monkeypatch.setattr(benchmark.subprocess, "run", fake_run)

    benchmark._run_batch(
        batch,
        artifacts[batch.case.model_id],
        corpus,
        prompt,
        output_path,
        schedule_path,
        repetitions=1,
        qwen_model_directory=None,
        qwen_checksum=None,
    )

    assert len(calls) == 1
    environment = calls[0]["env"]
    assert "CNS_BENCHMARK_SAMPLE_ID" not in environment
    assert environment["CNS_BENCHMARK_PROMPT_SHA256"] == "p" * 64
    assert json.loads(Path(environment["CNS_BENCHMARK_SCHEDULE"]).read_text(encoding="utf-8")) == {
        "schema_version": 1,
        "observations": [
            {"sample_id": "001", "repetition": 0, "temperature": "cold"},
            {"sample_id": "002", "repetition": 0, "temperature": "warm"},
            {"sample_id": "001", "repetition": 1, "temperature": "warm"},
        ],
    }


def test_validate_result_rows_accepts_exact_complete_schedule(tmp_path: Path) -> None:
    corpus = make_corpus(tmp_path)
    matrix = benchmark.build_matrix(d_model_id=None)
    artifacts = make_artifacts(matrix, tmp_path)
    rows = [
        make_result_row(
            item.case,
            artifacts[item.case.model_id],
            corpus,
            item.sample_id,
            item.repetition,
            item.temperature,
            1,
        )
        for item in benchmark.build_run_schedule(
            matrix,
            corpus,
            repetitions=1,
            control_sample_ids={"001"},
        )
    ]
    for row in rows:
        row["chunk_count"] = 1
        row["chunk_sample_counts"] = [row["transcribed_sample_count"]]

    benchmark.validate_result_rows(
        rows,
        matrix=matrix,
        artifacts=artifacts,
        corpus=corpus,
        repetitions=1,
        prompt_checksum="p" * 64,
        control_sample_ids={"001"},
    )


def test_validate_result_rows_rejects_two_row_partial_output(tmp_path: Path) -> None:
    corpus = make_corpus(tmp_path)
    matrix = benchmark.build_matrix(d_model_id=None)
    artifacts = make_artifacts(matrix, tmp_path)
    schedule = benchmark.build_run_schedule(
        matrix,
        corpus,
        repetitions=1,
        control_sample_ids={"001"},
    )
    rows = [
        make_result_row(
            item.case,
            artifacts[item.case.model_id],
            corpus,
            item.sample_id,
            item.repetition,
            item.temperature,
            1,
        )
        for item in schedule[:2]
    ]

    with pytest.raises(benchmark.ValidationError, match="expected 6 result rows, found 2"):
        benchmark.validate_result_rows(
            rows,
            matrix=matrix,
            artifacts=artifacts,
            corpus=corpus,
            repetitions=1,
            prompt_checksum="p" * 64,
            control_sample_ids={"001"},
        )


def test_validate_result_rows_rejects_nan_duration(tmp_path: Path) -> None:
    corpus = make_corpus(tmp_path, sample_ids=("001",))
    matrix = benchmark.build_matrix(d_model_id=None)
    artifacts = make_artifacts(matrix, tmp_path)
    schedule = benchmark.build_run_schedule(
        matrix,
        corpus,
        repetitions=1,
        control_sample_ids={"001"},
    )
    rows = [
        make_result_row(
            item.case,
            artifacts[item.case.model_id],
            corpus,
            item.sample_id,
            item.repetition,
            item.temperature,
            1,
        )
        for item in schedule
    ]
    rows[0]["stop_to_preview_seconds"] = math.nan

    with pytest.raises(benchmark.ValidationError, match="finite"):
        benchmark.validate_result_rows(
            rows,
            matrix=matrix,
            artifacts=artifacts,
            corpus=corpus,
            repetitions=1,
            prompt_checksum="p" * 64,
            control_sample_ids={"001"},
        )


def test_validate_result_rows_rejects_inconsistent_case_metadata(tmp_path: Path) -> None:
    corpus = make_corpus(tmp_path, sample_ids=("001",))
    matrix = benchmark.build_matrix(d_model_id=None)
    artifacts = make_artifacts(matrix, tmp_path)
    schedule = benchmark.build_run_schedule(
        matrix,
        corpus,
        repetitions=1,
        control_sample_ids={"001"},
    )
    rows = [
        make_result_row(
            item.case,
            artifacts[item.case.model_id],
            corpus,
            item.sample_id,
            item.repetition,
            item.temperature,
            1,
        )
        for item in schedule
    ]
    rows[0]["model_id"] = "whisper-small"

    with pytest.raises(benchmark.ValidationError, match="model_id"):
        benchmark.validate_result_rows(
            rows,
            matrix=matrix,
            artifacts=artifacts,
            corpus=corpus,
            repetitions=1,
            prompt_checksum="p" * 64,
            control_sample_ids={"001"},
        )


def test_validate_result_rows_rejects_bucket_that_can_inflate_short_accuracy(tmp_path: Path) -> None:
    corpus = make_corpus(tmp_path, sample_ids=("001",))
    matrix = benchmark.build_matrix(d_model_id=None)
    artifacts = make_artifacts(matrix, tmp_path)
    schedule = benchmark.build_run_schedule(
        matrix,
        corpus,
        repetitions=1,
        control_sample_ids={"001"},
    )
    rows = [
        make_result_row(
            item.case,
            artifacts[item.case.model_id],
            corpus,
            item.sample_id,
            item.repetition,
            item.temperature,
            1,
        )
        for item in schedule
    ]
    rows[0]["bucket"] = "medium"

    with pytest.raises(benchmark.ValidationError, match="bucket"):
        benchmark.validate_result_rows(
            rows,
            matrix=matrix,
            artifacts=artifacts,
            corpus=corpus,
            repetitions=1,
            prompt_checksum="p" * 64,
            control_sample_ids={"001"},
        )


def test_validate_result_rows_rejects_inflated_reference_word_count(tmp_path: Path) -> None:
    corpus = make_corpus(tmp_path, sample_ids=("001",))
    matrix = benchmark.build_matrix(d_model_id=None)
    artifacts = make_artifacts(matrix, tmp_path)
    schedule = benchmark.build_run_schedule(
        matrix,
        corpus,
        repetitions=1,
        control_sample_ids={"001"},
    )
    rows = [
        make_result_row(
            item.case,
            artifacts[item.case.model_id],
            corpus,
            item.sample_id,
            item.repetition,
            item.temperature,
            1,
        )
        for item in schedule
    ]
    rows[0]["reference_word_count"] += 100

    with pytest.raises(benchmark.ValidationError, match="reference_word_count"):
        benchmark.validate_result_rows(
            rows,
            matrix=matrix,
            artifacts=artifacts,
            corpus=corpus,
            repetitions=1,
            prompt_checksum="p" * 64,
            control_sample_ids={"001"},
        )


def test_aggregate_rows_reports_cold_and_warm_latency_and_outcomes() -> None:
    rows = [
        {"case_id": "A", "temperature": "cold", "stop_to_text_seconds": 4.0, "outcome": "success"},
        {"case_id": "A", "temperature": "warm", "stop_to_text_seconds": 1.0, "outcome": "success"},
        {"case_id": "A", "temperature": "warm", "stop_to_text_seconds": 3.0, "outcome": "timed_out"},
    ]

    summary = benchmark.aggregate_rows(rows, expected_case_ids={"A"})

    assert summary["A"]["cold"] == {
        "n": 1,
        "median_seconds": 4.0,
        "p95_seconds": 4.0,
        "max_seconds": 4.0,
        "outcomes": {"success": 1},
    }
    assert summary["A"]["warm"] == {
        "n": 2,
        "median_seconds": 2.0,
        "p95_seconds": 3.0,
        "max_seconds": 3.0,
        "outcomes": {"success": 1, "timed_out": 1},
    }


def test_aggregate_rows_fails_when_a_matrix_case_has_no_results() -> None:
    with pytest.raises(benchmark.ValidationError, match="missing benchmark results for cases: C"):
        benchmark.aggregate_rows(
            [{"case_id": "B", "temperature": "warm", "stop_to_text_seconds": 1.0, "outcome": "success"}],
            expected_case_ids={"B", "C"},
        )


def test_aggregate_rows_fails_when_cold_or_warm_classification_is_absent() -> None:
    with pytest.raises(benchmark.ValidationError, match="missing cold results for case: C"):
        benchmark.aggregate_rows(
            [
                {
                    "case_id": "C",
                    "temperature": "warm",
                    "stop_to_text_seconds": 1.0,
                    "outcome": "success",
                }
            ],
            expected_case_ids={"C"},
        )


def test_aggregate_quality_uses_full_corpus_pass_without_repeated_control_bias() -> None:
    rows = [
        {
            "case_id": "B",
            "repetition": 0,
            "language": "ru",
            "bucket": "short",
            "word_errors": 1,
            "reference_word_count": 4,
            "term_hits": 1,
            "term_total": 2,
        },
        {
            "case_id": "B",
            "repetition": 0,
            "language": "en",
            "bucket": "medium",
            "word_errors": 0,
            "reference_word_count": 6,
            "term_hits": 2,
            "term_total": 2,
        },
        {
            "case_id": "B",
            "repetition": 1,
            "language": "ru",
            "bucket": "short",
            "word_errors": 99,
            "reference_word_count": 1,
            "term_hits": 0,
            "term_total": 99,
        },
    ]

    quality = benchmark.aggregate_quality(rows, expected_case_ids={"B"})

    assert quality["B"] == {
        "sample_count": 2,
        "overall_wer": 0.1,
        "wer_by_language": {"en": 0.0, "ru": 0.25},
        "short_command_accuracy": 0.75,
        "term_recall": 0.75,
    }


def test_full_pipeline_matrix_marks_qwen_pass_separately_from_stt_only() -> None:
    matrix = benchmark.build_matrix(d_model_id=None, include_qwen=True)

    assert [(case.case_id, case.pipeline_profile) for case in matrix] == [
        ("B", "full_pipeline_stt_only"),
        ("C", "full_pipeline_stt_only"),
        ("B", "full_pipeline_local_qwen"),
        ("C", "full_pipeline_local_qwen"),
    ]
    assert benchmark.BENCHMARK_SCOPE == "full_pipeline_audiochunker_vad_session"


def test_model_choice_is_ineligible_without_successful_qwen_b_and_c_results() -> None:
    matrix = benchmark.build_matrix(d_model_id=None, include_qwen=True)
    rows = [
        {
            "case_id": "B",
            "pipeline_profile": "full_pipeline_local_qwen",
            "outcome": "success",
        },
        {
            "case_id": "C",
            "pipeline_profile": "full_pipeline_local_qwen",
            "outcome": "timed_out",
        },
    ]

    eligible, blocker = benchmark.model_choice_eligibility(rows, matrix=matrix)

    assert eligible is False
    assert "successful full-pipeline" in blocker


def test_model_choice_rejects_qwen_results_that_miss_a_quality_gate() -> None:
    matrix = benchmark.build_matrix(d_model_id=None, include_qwen=True)
    rows: list[dict[str, Any]] = []
    for case in matrix:
        if case.pipeline_profile != "full_pipeline_local_qwen":
            continue
        for language, bucket, errors in [
            ("ru", "short", 0 if case.case_id == "B" else 6),
            ("en", "medium", 0),
            ("ru+en", "long", 0),
        ]:
            rows.append(
                {
                    "case_id": case.case_id,
                    "pipeline_profile": case.pipeline_profile,
                    "outcome": "success",
                    "editor_outcome": "ok",
                    "repetition": 0,
                    "language": language,
                    "bucket": bucket,
                    "word_errors": errors,
                    "reference_word_count": 100,
                    "term_hits": 10,
                    "term_total": 10,
                }
            )

    eligible, blocker = benchmark.model_choice_eligibility(rows, matrix=matrix)

    assert eligible is False
    assert blocker is not None
    assert "quality gate" in blocker
    assert "C" in blocker


def test_model_choice_allows_guarded_tails_when_quality_gates_pass() -> None:
    matrix = benchmark.build_matrix(d_model_id=None, include_qwen=True)
    rows: list[dict[str, Any]] = []
    for case in matrix:
        if case.pipeline_profile != "full_pipeline_local_qwen":
            continue
        for language, bucket, outcome in [
            ("ru", "short", "guarded_tiny_final_chunk"),
            ("en", "medium", "success"),
            ("ru+en", "long", "success"),
        ]:
            rows.append(
                {
                    "case_id": case.case_id,
                    "pipeline_profile": case.pipeline_profile,
                    "outcome": outcome,
                    "editor_outcome": "unchanged",
                    "repetition": 0,
                    "language": language,
                    "bucket": bucket,
                    "word_errors": 0,
                    "reference_word_count": 100,
                    "term_hits": 10,
                    "term_total": 10,
                }
            )

    eligible, blocker = benchmark.model_choice_eligibility(rows, matrix=matrix)

    assert eligible is True
    assert blocker is None


def test_model_choice_accepts_complete_qwen_results_that_meet_quality_gates() -> None:
    matrix = benchmark.build_matrix(d_model_id=None, include_qwen=True)
    rows: list[dict[str, Any]] = []
    for case in matrix:
        if case.pipeline_profile != "full_pipeline_local_qwen":
            continue
        for language, bucket in [("ru", "short"), ("en", "medium"), ("ru+en", "long")]:
            rows.append(
                {
                    "case_id": case.case_id,
                    "pipeline_profile": case.pipeline_profile,
                    "outcome": "success",
                    "editor_outcome": "unchanged",
                    "repetition": 0,
                    "language": language,
                    "bucket": bucket,
                    "word_errors": 0,
                    "reference_word_count": 100,
                    "term_hits": 10,
                    "term_total": 10,
                }
            )

    eligible, blocker = benchmark.model_choice_eligibility(rows, matrix=matrix)

    assert eligible is True
    assert blocker is None


def test_external_baseline_rejects_a_stt_only_or_incompatible_artifact(tmp_path: Path) -> None:
    baseline_path = tmp_path / "baseline.json"
    baseline_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "artifact_type": "clicknspeak_latency_baseline",
                "case_id": "A",
                "benchmark_scope": "stt_only_diagnostic",
                "implementation_revision": "abc123",
                "implementation_fingerprint": "a" * 64,
                "comparison_contract": {"corpus_sha256": "b" * 64},
                "latency": {
                    "stop_to_preview_seconds": {"n": 1, "median_seconds": 1.0, "p95_seconds": 1.0},
                    "stop_to_popup_seconds": {"n": 1, "median_seconds": 2.0, "p95_seconds": 2.0},
                },
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(benchmark.ValidationError, match="full-pipeline"):
        benchmark.validate_external_baseline(
            baseline_path,
            comparison_contract={"corpus_sha256": "b" * 64},
        )


def test_external_baseline_accepts_matching_full_pipeline_artifact(tmp_path: Path) -> None:
    baseline_path = tmp_path / "baseline.json"
    contract = {
        "corpus_sha256": "b" * 64,
        "adapter": "audiochunker_vad_session",
        "language_mode": "bilingual",
    }
    baseline_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "artifact_type": "clicknspeak_latency_baseline",
                "case_id": "A",
                "benchmark_scope": "full_pipeline_audiochunker_vad_session",
                "implementation_revision": "abc123",
                "implementation_fingerprint": "a" * 64,
                "comparison_contract": contract,
                "latency": {
                    "stop_to_preview_seconds": {"n": 1, "median_seconds": 1.0, "p95_seconds": 1.0},
                    "stop_to_popup_seconds": {"n": 1, "median_seconds": 2.0, "p95_seconds": 2.0},
                },
            }
        ),
        encoding="utf-8",
    )

    artifact = benchmark.validate_external_baseline(
        baseline_path,
        comparison_contract=contract,
    )

    assert artifact["case_id"] == "A"
