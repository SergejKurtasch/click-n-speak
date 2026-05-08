"""Tests for log_analyzer v2: improved filters, session-based dedup, Levenshtein, bigrams-only."""

from datetime import datetime, timedelta

import pytest

from src.log_analyzer import (
    _assign_session_ids,
    _collect_english_terms,
    _collect_russian_bigrams,
    _filter_near_duplicates,
    _levenshtein,
    _parse_history_lines,
    get_frequent_terms,
    get_prompt_candidates,
)
from src.utils import get_language_script, target_lang_for_script_bucket


# ---------------------------------------------------------------------------
# _levenshtein
# ---------------------------------------------------------------------------


class TestLevenshtein:
    def test_identical(self):
        assert _levenshtein("abc", "abc") == 0

    def test_single_insertion(self):
        assert _levenshtein("production", "roduction") == 1

    def test_single_substitution(self):
        assert _levenshtein("Github", "Guthub") == 1

    def test_early_exit_large_diff(self):
        # Length difference > 2 → immediately returns 3.
        assert _levenshtein("a", "abcde") == 3

    def test_empty_strings(self):
        assert _levenshtein("", "") == 0

    def test_one_empty(self):
        assert _levenshtein("abc", "") == 3  # early exit (diff > 2) → 3

    def test_two_edits(self):
        assert _levenshtein("kitten", "sitten") == 1


# ---------------------------------------------------------------------------
# _parse_history_lines
# ---------------------------------------------------------------------------


class TestParseHistoryLines:
    def test_valid_tsv(self):
        lines = ["2024-01-01T10:00:00\thello world\n"]
        records = _parse_history_lines(lines)
        assert len(records) == 1
        ts, text = records[0]
        assert ts == datetime(2024, 1, 1, 10, 0, 0)
        assert text == "hello world"

    def test_malformed_line_skipped(self):
        lines = ["no tab here\n", "2024-01-01T10:00:00\tgood line\n"]
        records = _parse_history_lines(lines)
        assert len(records) == 1

    def test_bad_timestamp_skipped(self):
        lines = ["not-a-date\tsome text\n"]
        records = _parse_history_lines(lines)
        assert records == []

    def test_empty_input(self):
        assert _parse_history_lines([]) == []


# ---------------------------------------------------------------------------
# _assign_session_ids
# ---------------------------------------------------------------------------


def _make_records(offsets_seconds: list[int]) -> list[tuple[datetime, str]]:
    """Build dummy records with timestamps offset from a base time."""
    base = datetime(2024, 1, 1, 12, 0, 0)
    return [(base + timedelta(seconds=s), f"text {s}") for s in offsets_seconds]


class TestAssignSessionIds:
    def test_single_session_small_gaps(self):
        records = _make_records([0, 30, 59])
        ids = _assign_session_ids(records)
        assert ids == [0, 0, 0]

    def test_new_session_at_60s_gap(self):
        records = _make_records([0, 60])
        ids = _assign_session_ids(records)
        assert ids == [0, 1]

    def test_multiple_sessions(self):
        records = _make_records([0, 30, 90, 150, 300])
        ids = _assign_session_ids(records)
        # gap 30<60 → same; 90-30=60 → new; 150-90=60 → new; 300-150=150 → new
        assert ids == [0, 0, 1, 2, 3]

    def test_empty(self):
        assert _assign_session_ids([]) == []

    def test_single_record(self):
        records = _make_records([0])
        assert _assign_session_ids(records) == [0]


# ---------------------------------------------------------------------------
# _collect_english_terms
# ---------------------------------------------------------------------------


def _records_with_sessions(
    entries: list[tuple[int, str]],
) -> tuple[list[tuple[datetime, str]], list[int]]:
    """Build (records, session_ids) directly from (session_id, text) pairs."""
    base = datetime(2024, 1, 1, 12, 0, 0)
    records = [(base, text) for _, text in entries]
    session_ids = [sid for sid, _ in entries]
    return records, session_ids


class TestCollectEnglishTerms:
    def test_requires_two_sessions(self):
        records, sids = _records_with_sessions([(0, "PCA analysis"), (0, "PCA again")])
        result = _collect_english_terms(records, sids)
        terms = [t for t, _ in result]
        assert "PCA" not in terms

    def test_passes_two_sessions(self):
        records, sids = _records_with_sessions([(0, "PCA analysis"), (1, "PCA again")])
        result = _collect_english_terms(records, sids)
        terms = [t for t, _ in result]
        assert "PCA" in terms

    def test_stoplist_filtered(self):
        records, sids = _records_with_sessions([(0, "the https www"), (1, "the https www")])
        result = _collect_english_terms(records, sids)
        assert result == []

    def test_url_fragment_skipped(self):
        # More than one dot → path/URL fragment
        records, sids = _records_with_sessions(
            [(0, "go to github.com/user/repo"), (1, "check github.com/user/repo")]
        )
        result = _collect_english_terms(records, sids)
        terms = [t for t, _ in result]
        assert "github.com/user/repo" not in terms

    def test_case_normalization_keeps_most_frequent(self):
        # session 0: GitHub x2, github x1 → best variant = GitHub
        records, sids = _records_with_sessions([
            (0, "GitHub GitHub github"),
            (1, "GitHub"),
        ])
        result = _collect_english_terms(records, sids)
        terms = [t for t, _ in result]
        assert "GitHub" in terms
        assert "github" not in terms

    def test_blacklist_excluded(self):
        records, sids = _records_with_sessions([(0, "PCA"), (1, "PCA")])
        result = _collect_english_terms(records, sids, blacklist=frozenset({"pca"}))
        assert result == []

    def test_sorted_by_count_descending(self):
        records, sids = _records_with_sessions([
            (0, "alpha beta"),
            (1, "alpha beta beta beta"),
        ])
        result = _collect_english_terms(records, sids)
        terms = [t for t, _ in result]
        assert terms.index("beta") < terms.index("alpha")

    def test_term_must_start_with_letter(self):
        # "123abc" starts with digit — should not match _TERM_PATTERN
        records, sids = _records_with_sessions([(0, "123abc"), (1, "123abc")])
        result = _collect_english_terms(records, sids)
        terms = [t for t, _ in result]
        assert "123abc" not in terms

    def test_trailing_punctuation_collapses_to_same_term(self):
        records, sids = _records_with_sessions([(0, "GitHub."), (1, "GitHub")])
        result = _collect_english_terms(records, sids)
        terms = [t for t, _ in result]
        assert "GitHub" in terms
        assert "GitHub." not in terms


# ---------------------------------------------------------------------------
# _filter_near_duplicates
# ---------------------------------------------------------------------------


class TestFilterNearDuplicates:
    def test_drops_edit_distance_1(self):
        # "production" vs "roduction" — dist 1 → drop the less frequent (second).
        candidates = [("production", 10), ("roduction", 3)]
        result = _filter_near_duplicates(candidates)
        assert [t for t, _ in result] == ["production"]

    def test_keeps_dist_2(self):
        candidates = [("alpha", 5), ("alp", 5)]
        result = _filter_near_duplicates(candidates)
        # "alpha" vs "alp" has length diff 2 → levenshtein = 2 → not near-dup
        assert len(result) == 2

    def test_no_duplicates_passthrough(self):
        candidates = [("PCA", 10), ("survival", 8), ("bootstrap", 5)]
        assert _filter_near_duplicates(candidates) == candidates

    def test_keeps_more_frequent(self):
        # Github (10) vs Guthub (2) — dist 1, keep Github.
        candidates = [("Github", 10), ("Guthub", 2)]
        result = _filter_near_duplicates(candidates)
        assert [t for t, _ in result] == ["Github"]

    def test_empty(self):
        assert _filter_near_duplicates([]) == []


# ---------------------------------------------------------------------------
# _collect_russian_bigrams
# ---------------------------------------------------------------------------


class TestCollectRussianBigrams:
    def test_basic_bigram(self):
        counts = _collect_russian_bigrams(["машинное обучение данных"])
        assert counts["машинное обучение"] >= 1

    def test_no_trigrams(self):
        counts = _collect_russian_bigrams(["машинное обучение данных"])
        # Trigrams would look like "машинное обучение данных"
        assert "машинное обучение данных" not in counts

    def test_short_words_skipped(self):
        # "на" (2 chars) should be skipped
        counts = _collect_russian_bigrams(["на машинное обучение"])
        assert "на машинное" not in counts
        assert "машинное обучение" in counts

    def test_lowercased(self):
        counts = _collect_russian_bigrams(["Машинное Обучение"])
        assert "машинное обучение" in counts

    def test_empty(self):
        counts = _collect_russian_bigrams([])
        assert len(counts) == 0


# ---------------------------------------------------------------------------
# get_frequent_terms (integration — uses tmp file)
# ---------------------------------------------------------------------------


def _write_history(path, entries: list[tuple[str, str]]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for ts, text in entries:
            f.write(f"{ts}\t{text}\n")


class TestGetFrequentTerms:
    def test_returns_empty_when_no_file(self, tmp_path, monkeypatch):
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: tmp_path / "missing.txt")
        en, ru = get_frequent_terms()
        assert en == [] and ru == []

    def test_en_term_requires_two_sessions(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        _write_history(p, [
            ("2024-01-01T10:00:00", "PCA analysis"),
            ("2024-01-01T10:00:30", "PCA result"),   # same session (30s gap)
        ])
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        en, _ = get_frequent_terms()
        assert "PCA" not in en

    def test_en_term_two_sessions(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        _write_history(p, [
            ("2024-01-01T10:00:00", "PCA analysis"),
            ("2024-01-01T10:02:00", "PCA result"),   # 120s gap → new session
        ])
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        en, _ = get_frequent_terms()
        assert "PCA" in en

    def test_stoplist_excluded(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        _write_history(p, [
            ("2024-01-01T10:00:00", "https www"),
            ("2024-01-01T10:02:00", "https www"),
        ])
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        en, _ = get_frequent_terms()
        assert "https" not in en and "www" not in en

    def test_near_duplicate_dedup(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        _write_history(p, [
            ("2024-01-01T10:00:00", "production production production"),
            ("2024-01-01T10:02:00", "production roduction"),
        ])
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        en, _ = get_frequent_terms()
        assert "production" in en
        assert "roduction" not in en

    def test_ru_bigram_threshold_3(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        # Bigram appears only twice → should be filtered out (threshold is 3).
        _write_history(p, [
            ("2024-01-01T10:00:00", "машинное обучение"),
            ("2024-01-01T10:02:00", "машинное обучение"),
        ])
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        _, ru = get_frequent_terms(max_ru_phrases=5)
        assert "машинное обучение" not in ru

    def test_ru_bigram_passes_threshold_3(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        _write_history(p, [
            ("2024-01-01T10:00:00", "машинное обучение данных"),
            ("2024-01-01T10:01:00", "машинное обучение данных"),
            ("2024-01-01T10:02:00", "машинное обучение данных"),
        ])
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        _, ru = get_frequent_terms(max_ru_phrases=5)
        assert "машинное обучение" in ru

    def test_blacklist_respected(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        _write_history(p, [
            ("2024-01-01T10:00:00", "PCA analysis"),
            ("2024-01-01T10:02:00", "PCA result"),
        ])
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        en, _ = get_frequent_terms(blacklist=frozenset({"pca"}))
        assert "PCA" not in en


# ---------------------------------------------------------------------------
# Script bucket helpers (language-agnostic thresholds)
# ---------------------------------------------------------------------------


class TestLanguageScriptHelpers:
    def test_get_language_script(self):
        assert get_language_script("ru") == "cyrillic"
        assert get_language_script("ua") == "cyrillic"
        assert get_language_script("de") == "latin"
        assert get_language_script("en") == "latin"

    def test_target_lang_for_script_bucket(self):
        assert target_lang_for_script_bucket("latin", "ru", ["en"]) == "en"
        assert target_lang_for_script_bucket("cyrillic", "ru", ["en"]) == "ru"
        assert target_lang_for_script_bucket("latin", "de", ["en"]) == "de"


# ---------------------------------------------------------------------------
# get_prompt_candidates (script buckets + min_count dict)
# ---------------------------------------------------------------------------


def _write_history_lines(path, entries: list[tuple[str, str]]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for ts, text in entries:
            f.write(f"{ts}\t{text}\n")


class TestGetPromptCandidates:
    def test_min_count_dict_per_script(self, tmp_path, monkeypatch):
        """Latin threshold 5 passes MLX; Cyrillic bigram count 5 fails threshold 8."""
        p = tmp_path / "phrases.txt"
        latin_lines = [
            ("2024-01-01T10:00:00", "MLX term"),
            ("2024-01-01T10:01:00", "MLX alpha"),
            ("2024-01-01T10:02:00", "MLX beta"),
            ("2024-01-01T10:03:00", "MLX gamma"),
            ("2024-01-01T11:05:00", "MLX delta"),
        ]
        ru_lines = [
            ("2024-01-02T10:00:00", "машинное обучение данных"),
            ("2024-01-02T10:02:00", "машинное обучение данных"),
            ("2024-01-02T10:04:00", "машинное обучение данных"),
            ("2024-01-02T10:06:00", "машинное обучение данных"),
            ("2024-01-02T10:08:00", "машинное обучение данных"),
        ]
        _write_history_lines(p, latin_lines + ru_lines)
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        out = get_prompt_candidates(
            lookback=500,
            min_count={"latin": 5, "cyrillic": 8},
            existing_lower_by_lang={},
            skipped_lower_by_lang={},
            current_phrase_count=0,
        )
        terms_latin = [x["term"] for x in out.get("latin", [])]
        assert "MLX" in terms_latin
        assert "машинное обучение" not in [x["term"] for x in out.get("cyrillic", [])]

    def test_correction_signal_bypasses_session_filter(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        # Single session (all gaps < 60s); bypass allows MLX despite one session.
        _write_history_lines(
            p,
            [
                ("2024-01-01T10:00:00", "MLX one"),
                ("2024-01-01T10:00:20", "MLX two"),
                ("2024-01-01T10:00:40", "MLX three"),
                ("2024-01-01T10:00:50", "MLX four"),
                ("2024-01-01T10:00:55", "MLX five"),
            ],
        )
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        out = get_prompt_candidates(
            min_count={"latin": 5, "cyrillic": 8},
            term_has_correction_signal=lambda t: t == "mlx",
            existing_lower_by_lang={},
            skipped_lower_by_lang={},
            current_phrase_count=0,
        )
        assert any(x["term"] == "MLX" for x in out.get("latin", []))

    def test_no_correction_signal_keeps_session_filter(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        # Single session only — without bypass, ≥2 sessions required.
        _write_history_lines(
            p,
            [
                ("2024-01-01T10:00:00", "MLX one"),
                ("2024-01-01T10:00:20", "MLX two"),
                ("2024-01-01T10:00:40", "MLX three"),
                ("2024-01-01T10:00:50", "MLX four"),
                ("2024-01-01T10:00:55", "MLX five"),
            ],
        )
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        out = get_prompt_candidates(
            min_count={"latin": 5, "cyrillic": 8},
            term_has_correction_signal=None,
            existing_lower_by_lang={},
            skipped_lower_by_lang={},
            current_phrase_count=0,
        )
        assert "latin" not in out or not any(x["term"] == "MLX" for x in out["latin"])

    def test_default_min_count_none(self, tmp_path, monkeypatch):
        p = tmp_path / "phrases.txt"
        _write_history_lines(
            p,
            [
                ("2024-01-01T10:00:00", "PCA x"),
                ("2024-01-01T11:05:00", "PCA y"),
                ("2024-01-01T11:06:00", "PCA z"),
                ("2024-01-01T11:07:00", "PCA a"),
                ("2024-01-01T11:08:00", "PCA b"),
            ],
        )
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        out = get_prompt_candidates(min_count=None, existing_lower_by_lang={}, skipped_lower_by_lang={}, current_phrase_count=0)
        assert any(x["term"] == "PCA" for x in out.get("latin", []))

    def test_lookback_truncates_old_lines(self, tmp_path, monkeypatch):
        # RareTok: 5 mentions in 2 sessions — then 350 filler lines — deque(300) drops RareTok.
        rows = [
            ("2024-01-01T10:00:00", "RareTok a"),
            ("2024-01-01T10:01:00", "RareTok b"),
            ("2024-01-01T11:05:00", "RareTok c"),
            ("2024-01-01T11:06:00", "RareTok d"),
            ("2024-01-01T11:07:00", "RareTok e"),
        ]
        for i in range(350):
            rows.append((f"2024-02-01T08:{i // 60:02d}:{i % 60:02d}", "padding text"))
        rows += [
            ("2024-03-01T12:00:00", "NEWTOKEN a"),
            ("2024-03-01T12:01:00", "NEWTOKEN b"),
            ("2024-03-01T12:02:00", "NEWTOKEN c"),
            ("2024-03-01T12:03:00", "NEWTOKEN d"),
            ("2024-03-01T12:04:00", "NEWTOKEN e"),
        ]
        p = tmp_path / "phrases.txt"
        _write_history_lines(p, rows)
        monkeypatch.setattr("src.log_analyzer.get_phrases_file_path", lambda: p)
        out = get_prompt_candidates(
            lookback=300,
            min_count={"latin": 5, "cyrillic": 8},
            existing_lower_by_lang={},
            skipped_lower_by_lang={},
            current_phrase_count=0,
        )
        latin_terms = [x["term"] for x in out.get("latin", [])]
        assert "NEWTOKEN" in latin_terms
        assert "RareTok" not in latin_terms
