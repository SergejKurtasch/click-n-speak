# Verification

Use the repository virtual environment for root tooling and contract tests:
`venv/bin/python -m pytest <test-path> -q`. Set up the local command-line
toolchain with `brew bundle`, then use `venv/bin/python
scripts/check_dev_environment.py` as the first diagnostic command. The doctor
is read-only and reports missing dependencies without installing them.
For Swift package work, run `swift test --disable-index-store --package-path
Packages/<Package>`; for app-wide Swift checks, use `swift test
--disable-index-store --package-path ClickNSpeak` and `bash
scripts/swift_verify.sh` as appropriate.

Create the release application with `bash scripts/swift_build_app.sh release`.
Model suites are opt-in: use `CNS_RUN_MODEL_TESTS=1` or
`CNS_RUN_EDITOR_MODEL_TESTS=1` only with explicit local model paths.

On a failure, first run the smallest owning test target, inspect the failing
contract and fixture, then expand to the relevant package or full verifier.
Do not treat real-model failures as ordinary unit-test evidence.
