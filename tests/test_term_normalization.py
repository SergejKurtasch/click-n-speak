from src.utils import canonical_term_key, canonicalize_term


def test_canonicalize_term_strips_boundary_punctuation_only():
    assert canonicalize_term("  (GitHub),  ") == "GitHub"
    assert canonicalize_term("'Cursor.'") == "Cursor"


def test_canonicalize_term_preserves_inner_symbols():
    assert canonicalize_term("C++") == "C++"
    assert canonicalize_term("C#") == "C#"
    assert canonicalize_term("node.js") == "node.js"
    assert canonicalize_term("v2.1") == "v2.1"
    assert canonicalize_term("foo_bar") == "foo_bar"
    assert canonicalize_term("x-y") == "x-y"


def test_canonicalize_term_preserves_semantic_leading_markers():
    assert canonicalize_term(".NET") == ".NET"
    assert canonicalize_term("(@mention)") == "@mention"


def test_canonical_term_key_collapses_trailing_punctuation():
    assert canonical_term_key("GitHub.") == canonical_term_key("GitHub")
    assert canonical_term_key("GitHub,") == "github"
    assert canonical_term_key(".NET") == ".net"
