"""Tests for v2 initial-prompt schema: parse_prompt_terms, deduplicate_prompt_terms,
build_initial_prompt, and migrate_config_to_v2."""

import pytest
from src.utils import (
    build_initial_prompt,
    deduplicate_prompt_terms,
    get_allowed_languages,
    LANG_PROMPTS,
    migrate_config_to_v2,
    normalize_ukrainian_lang_codes,
    parse_prompt_terms,
)


# ---------------------------------------------------------------------------
# parse_prompt_terms
# ---------------------------------------------------------------------------

class TestParsePromptTerms:
    def test_comma_separated(self):
        assert parse_prompt_terms("PCA, survival, bootstrap") == ["PCA", "survival", "bootstrap"]

    def test_strips_trailing_dots_per_token(self):
        # Dots at the end of a comma-separated token are stripped.
        assert parse_prompt_terms("PCA., survival.") == ["PCA", "survival"]

    def test_newline_as_delimiter(self):
        assert parse_prompt_terms("PCA\nsurvival\nbootstrap") == ["PCA", "survival", "bootstrap"]

    def test_filters_standalone_lang_hints(self):
        # Lang-hint phrases that appear as standalone comma-separated tokens are dropped.
        result = parse_prompt_terms("Русский язык, English language, PCA")
        assert "Русский язык" not in result
        assert "English language" not in result
        assert "PCA" in result

    def test_skips_blank_tokens(self):
        assert parse_prompt_terms(",, , PCA ,") == ["PCA"]

    def test_deduplicates_within_parse(self):
        result = parse_prompt_terms("PCA, pca, PCA")
        assert result.count("PCA") == 1

    def test_empty_string(self):
        assert parse_prompt_terms("") == []


# ---------------------------------------------------------------------------
# deduplicate_prompt_terms
# ---------------------------------------------------------------------------

class TestDeduplicatePromptTerms:
    def test_case_insensitive_dedup(self):
        result = deduplicate_prompt_terms(["Readmission", "readmission", "READMISSION"])
        assert result == ["Readmission"]

    def test_preserves_first_occurrence(self):
        result = deduplicate_prompt_terms(["github", "GitHub"])
        assert result == ["github"]

    def test_skips_empty_strings(self):
        result = deduplicate_prompt_terms(["PCA", "", "  ", "survival"])
        assert result == ["PCA", "survival"]

    def test_no_duplicates_passthrough(self):
        terms = ["PCA", "survival", "bootstrap"]
        assert deduplicate_prompt_terms(terms) == terms


# ---------------------------------------------------------------------------
# build_initial_prompt
# ---------------------------------------------------------------------------

class TestBuildInitialPrompt:
    def _cfg(self, **kw):
        base = {"primary_language": "ru", "additional_languages": [], "user_terms": {}, "auto_terms": {}}
        base.update(kw)
        return base

    def test_language_hint_prefix(self):
        cfg = self._cfg()
        result = build_initial_prompt(cfg)
        assert result.startswith(LANG_PROMPTS["ru"])

    def test_multiple_lang_hints(self):
        cfg = self._cfg(additional_languages=["en"])
        result = build_initial_prompt(cfg)
        assert LANG_PROMPTS["ru"] in result
        assert LANG_PROMPTS["en"] in result

    def test_user_terms_included(self):
        cfg = self._cfg(user_terms={"ru": ["PCA", "survival"]})
        result = build_initial_prompt(cfg)
        assert "PCA" in result
        assert "survival" in result

    def test_auto_terms_merged_into_user_terms(self):
        # Since Etap 7, auto_terms no longer exist — accepted candidates go directly
        # into user_terms. Both keys must be present in user_terms to appear in prompt.
        cfg = self._cfg(
            user_terms={"ru": ["PCA", "Hugging Face"]},
        )
        result = build_initial_prompt(cfg)
        assert "PCA" in result
        assert "Hugging Face" in result

    def test_cap_at_token_budget(self):
        # Token-accurate truncation: prompt must stay within _MAX_PROMPT_TOKENS tokens.
        # We use English terms (1-2 tokens each) and a large list to force truncation.
        long_terms = [f"term{i}" for i in range(200)]
        cfg = self._cfg(user_terms={"en": long_terms})
        result = build_initial_prompt(cfg)
        # The prompt must be non-empty and not absurdly long
        assert len(result) > 0
        assert len(result) <= 800  # hard upper bound (200 tokens × 4 chars/token)

    def test_no_terms_falls_back_to_default_context(self):
        # When user_terms is empty/absent, build_initial_prompt returns the lang hint
        # plus the default style sentence (added in Etap 7 as LANG_DEFAULT_CONTEXT).
        # Legacy config.initial_prompt is no longer read (removed in Etap 6).
        cfg = {"primary_language": "ru", "additional_languages": []}
        result = build_initial_prompt(cfg)
        assert "Русский язык" in result
        assert len(result) > 0

    def test_empty_config(self):
        # Since Etap 7, empty user_terms → lang hint + LANG_DEFAULT_CONTEXT style sentence.
        cfg = {"primary_language": "ru", "additional_languages": []}
        result = build_initial_prompt(cfg)
        assert result.startswith(LANG_PROMPTS["ru"])
        assert len(result) > len(LANG_PROMPTS["ru"])

    def test_ukrainian_prompt_hint_uses_uk_code(self):
        cfg = self._cfg(primary_language="uk")
        result = build_initial_prompt(cfg)
        assert result.startswith(LANG_PROMPTS["uk"])


# ---------------------------------------------------------------------------
# migrate_config_to_v2
# ---------------------------------------------------------------------------

class TestMigrateConfigToV2:
    def _v1_config(self):
        return {
            "primary_language": "ru",
            "additional_languages": ["en"],
            "initial_prompt": "PCA, survival, Readmission",
            "custom_prompts": {
                "ru": "PCA, survival, Readmission",
                "de": "Deutscher Text.",
            },
            "previous_prompts": {"ru": "PCA, survival"},
            "previous_initial_prompt": "old stuff",
            "language_hint": "",
            "terms_hint": "",
        }

    def test_sets_schema_version(self):
        cfg = migrate_config_to_v2(self._v1_config())
        assert cfg["schema_version"] == 2

    def test_idempotent(self):
        cfg = self._v1_config()
        cfg1 = migrate_config_to_v2(cfg)
        user_terms_before = list(cfg1.get("user_terms", {}).get("ru", []))
        cfg2 = migrate_config_to_v2(cfg1)
        assert cfg2.get("user_terms", {}).get("ru") == user_terms_before

    def test_user_terms_populated(self):
        cfg = migrate_config_to_v2(self._v1_config())
        terms = cfg["user_terms"]["ru"]
        assert "PCA" in terms
        assert "survival" in terms
        assert "Readmission" in terms

    def test_deduplication_on_migration(self):
        cfg = self._v1_config()
        cfg["custom_prompts"]["ru"] = "PCA, pca, PCA"
        result = migrate_config_to_v2(cfg)
        terms = result["user_terms"]["ru"]
        assert terms.count("PCA") == 1

    def test_lang_hints_not_in_user_terms(self):
        cfg = migrate_config_to_v2(self._v1_config())
        ru_terms = cfg["user_terms"]["ru"]
        assert "Русский язык" not in ru_terms
        assert "English language" not in ru_terms

    def test_lang_hint_only_lang_not_stored(self):
        cfg = migrate_config_to_v2(self._v1_config())
        # "de" had only "Deutscher Text." — a lang hint, so no user_terms for de
        assert "de" not in cfg.get("user_terms", {})

    def test_v1_keys_removed(self):
        cfg = migrate_config_to_v2(self._v1_config())
        for key in ("custom_prompts", "previous_prompts", "previous_initial_prompt",
                    "language_hint", "terms_hint"):
            assert key not in cfg, f"v1 key '{key}' should be removed after migration"

    def test_auto_terms_created(self):
        cfg = migrate_config_to_v2(self._v1_config())
        assert cfg.get("auto_terms") == {}

    def test_prompt_snapshots_created(self):
        cfg = migrate_config_to_v2(self._v1_config())
        assert cfg.get("prompt_snapshots") == {}

    def test_initial_prompt_refreshed(self):
        cfg = migrate_config_to_v2(self._v1_config())
        prompt = cfg["initial_prompt"]
        assert "Русский язык." in prompt
        assert "PCA" in prompt


class TestUkLangCodeNormalization:
    def test_get_allowed_languages_maps_legacy_ua(self):
        cfg = {"primary_language": "ua", "additional_languages": ["de", "ua"]}
        assert get_allowed_languages(cfg) == ["uk", "de"]

    def test_normalize_ukrainian_lang_codes_merges_language_sections(self):
        cfg = {
            "primary_language": "ua",
            "additional_languages": ["ua", "de", "uk"],
            "user_terms": {"ua": ["термін", "PCA"], "uk": ["PCA", "seed"]},
            "pending_suggestions": {"ua": [{"term": "GitHub", "count": 2}]},
            "prompt_snapshots": {"ua": ["foo"], "uk": ["foo", "bar"]},
            "skipped_terms": {"ua": {"github.": 11}, "uk": {"github": 7}},
        }
        out = normalize_ukrainian_lang_codes(cfg)

        assert out["primary_language"] == "uk"
        assert out["additional_languages"] == ["de"]
        assert out["user_terms"]["uk"] == ["термін", "PCA", "seed"]
        assert out["pending_suggestions"]["uk"][0]["term"] == "GitHub"
        assert out["prompt_snapshots"]["uk"] == ["foo", "bar"]
        assert out["skipped_terms"]["uk"]["github"] == 11
