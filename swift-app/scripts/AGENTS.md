# Scripts Guide

Scripts are safe developer entrypoints for build, acceptance, benchmark, and
release work. Prefer the canonical commands in the root guide. Run ordinary
Swift verification with `bash scripts/swift_verify.sh` and release builds with
`bash scripts/swift_build_app.sh release`.

Model-backed suites are opt-in: set `CNS_RUN_MODEL_TESTS=1` or
`CNS_RUN_EDITOR_MODEL_TESTS=1` only when explicit local model paths are
available. Do not enable them for ordinary unit validation.
