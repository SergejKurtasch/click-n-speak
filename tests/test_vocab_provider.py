from src.vocab_provider import add_term_to_user_terms


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
