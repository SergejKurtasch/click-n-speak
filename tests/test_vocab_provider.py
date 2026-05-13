import json

from src.correction_analyzer import remove_replacement_pair_from_index
from src.ai_editor import AiEditor
from src.app import _should_apply_direct_replacements_after_refine
from src.utils import migrate_config_to_v6
from src.vocab_provider import (
    add_term_to_user_terms,
    apply_replacements,
    collect_misrecognitions,
    collect_replacement_pairs_for_apply,
)


def _v5_config() -> dict:
    return {
        "schema_version": 5,
        "primary_language": "ru",
        "additional_languages": [],
        "user_terms": {"ru": []},
    }


def _v4_config() -> dict:
    return {
        "schema_version": 4,
        "primary_language": "ru",
        "additional_languages": [],
        "user_terms": {"ru": []},
    }


def test_add_term_to_user_terms_v5_dict_entry():
    cfg = _v5_config()
    added = add_term_to_user_terms(cfg, "ru", "GitHub", source="manual")

    assert added is True
    item = cfg["user_terms"]["ru"][0]
    assert item["term"] == "GitHub"
    assert item["source"] == "manual"
    assert item["use_count"] == 0
    assert item["added_at"]
    assert item["last_seen"]


def test_add_term_to_user_terms_dedupe_case_insensitive():
    cfg = _v5_config()
    assert add_term_to_user_terms(cfg, "ru", "github") is True
    assert add_term_to_user_terms(cfg, "ru", "GitHub") is False
    assert len(cfg["user_terms"]["ru"]) == 1


def test_add_term_to_user_terms_dedupe_trailing_punctuation():
    cfg = _v5_config()
    assert add_term_to_user_terms(cfg, "ru", "GitHub.") is True
    assert add_term_to_user_terms(cfg, "ru", "GitHub") is False
    assert len(cfg["user_terms"]["ru"]) == 1
    assert cfg["user_terms"]["ru"][0]["term"] == "GitHub"


def test_add_term_to_user_terms_v4_string_entry():
    cfg = _v4_config()
    added = add_term_to_user_terms(cfg, "ru", "  MLX  ")

    assert added is True
    assert cfg["user_terms"]["ru"] == ["MLX"]


def test_add_term_to_user_terms_rejects_empty_term():
    cfg = _v5_config()
    assert add_term_to_user_terms(cfg, "ru", "   ") is False
    assert cfg["user_terms"]["ru"] == []


def test_apply_replacements_word_boundary_case_insensitive():
    assert apply_replacements("Say Foo to foo.", [("foo", "bar")]) == "Say bar to bar."


def test_apply_replacements_multiword_from():
    pairs = [("one merge", "1 merge"), ("merge", "m")]
    assert apply_replacements("one merge please", pairs) == "1 merge please"


def test_apply_replacements_does_not_rewrite_replacement_output():
    pairs = [("github", "GitHub"), ("hub", "HUB")]
    assert apply_replacements("github hub", pairs) == "GitHub HUB"


def test_collect_misrecognitions_manual_before_auto(monkeypatch, tmp_path):
    corr = tmp_path / "corrections.json"
    corr.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "replacement_pairs": {
                    "latin": [{"from": "foo", "to": "bar", "count": 5}],
                    "cyrillic": [],
                },
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr("src.vocab_provider.get_corrections_file_path", lambda: corr)
    cfg = {
        "manual_replacements": [
            {"from": "alpha", "to": "beta", "added_at": "2026-01-01T00:00:00+00:00"}
        ]
    }
    out = collect_misrecognitions(["en"], config=cfg)
    assert out[0] == ("alpha", "beta")
    assert ("foo", "bar") in out


def test_collect_replacement_pairs_for_apply_sorts_longer_from_first(monkeypatch, tmp_path):
    corr = tmp_path / "corrections.json"
    corr.write_text(
        json.dumps(
            {
                "replacement_pairs": {
                    "latin": [
                        {"from": "ab", "to": "X", "count": 5},
                        {"from": "ab cd", "to": "Y", "count": 5},
                    ],
                    "cyrillic": [],
                },
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr("src.vocab_provider.get_corrections_file_path", lambda: corr)
    cfg: dict = {"manual_replacements": []}
    pairs = collect_replacement_pairs_for_apply(cfg, ["en"])
    assert pairs[0][0] == "ab cd"


def test_migrate_config_to_v6_manual_replacements_default():
    cfg = {"schema_version": 5, "primary_language": "ru"}
    migrate_config_to_v6(cfg)
    assert cfg["schema_version"] == 6
    assert cfg["manual_replacements"] == []


def test_should_apply_direct_replacements_external_unchanged_skips():
    assert not _should_apply_direct_replacements_after_refine(
        AiEditor.REFINE_STATUS_UNCHANGED,
        hints_in_prompt=True,
    )


def test_should_apply_direct_replacements_external_ok_skips():
    assert not _should_apply_direct_replacements_after_refine(
        AiEditor.REFINE_STATUS_OK,
        hints_in_prompt=True,
    )


def test_should_apply_direct_replacements_local_unchanged_applies():
    assert _should_apply_direct_replacements_after_refine(
        AiEditor.REFINE_STATUS_UNCHANGED,
        hints_in_prompt=False,
    )


def test_should_apply_direct_replacements_local_ok_skips():
    assert not _should_apply_direct_replacements_after_refine(
        AiEditor.REFINE_STATUS_OK,
        hints_in_prompt=False,
    )


def test_should_apply_direct_replacements_on_timeout():
    assert _should_apply_direct_replacements_after_refine(
        AiEditor.REFINE_STATUS_TIMEOUT,
        hints_in_prompt=True,
    )


def test_migrate_config_to_v6_idempotent():
    cfg = {"schema_version": 6, "manual_replacements": [{"from": "a", "to": "b", "added_at": "x"}]}
    migrate_config_to_v6(cfg)
    assert cfg["manual_replacements"][0]["from"] == "a"


def test_remove_replacement_pair_from_index_none_container(tmp_path):
    """Corrupt/null replacement_pairs must not crash removal attempts."""
    corr = tmp_path / "corrections.json"
    corr.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "inserted_terms": {"latin": {}, "cyrillic": {}},
                "replacement_pairs": None,
            }
        ),
        encoding="utf-8",
    )
    assert remove_replacement_pair_from_index("latin", "foo", "bar", corr) is False


def test_remove_replacement_pair_from_index(tmp_path):
    corr = tmp_path / "corrections.json"
    data = {
        "schema_version": 2,
        "last_processed_ts": None,
        "processed_rows": 0,
        "inserted_terms": {"latin": {}, "cyrillic": {}},
        "replacement_pairs": {
            "latin": [{"from": "foo", "to": "bar", "count": 2, "last_seen": "x"}],
            "cyrillic": [],
        },
    }
    corr.write_text(json.dumps(data), encoding="utf-8")
    assert remove_replacement_pair_from_index("latin", "foo", "bar", corr) is True
    roundtrip = json.loads(corr.read_text(encoding="utf-8"))
    assert roundtrip["replacement_pairs"]["latin"] == []
