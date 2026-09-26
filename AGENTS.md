# Click-n-speak — Agent Guide

Click-n-speak is a macOS menu-bar app: hotkey → audio capture →
speech-to-text → optional AI cleanup → editable preview → delivery to the
previously active app. The SwiftPM implementation in `ClickNSpeak/` and
`Packages/` is production; `main.py` and `src/` provide behavioral
compatibility and are not the packaged runtime.

## Working rules

- Responses and plans: Russian. Code, comments, docstrings, and commits: English.
- Preserve unrelated working-tree changes. Never discard or overwrite them.
- Use conventional commits: `feat:`, `fix:`, `refactor:`, `chore:`, `test:`, `docs:`.
- Never commit secrets, `.env`, runtime transcripts, prompts, clipboard data,
  model artifacts, or user configuration.
- Production code belongs in `ClickNSpeak/`, `Packages/`, or `src/`; tests in
  the corresponding test directory; developer utilities in `scripts/`.
- Python uses type hints, `pathlib`, `logging` for disk/network work, and
  specific exceptions.

## Canonical verification commands

Python commands use the repository virtual environment directly; do not wrap
Swift commands in `source venv/bin/activate`.

```bash
venv/bin/python -m pytest <test-path> -q
swift test --disable-index-store --package-path Packages/<Package>
swift test --disable-index-store --package-path ClickNSpeak
bash scripts/swift_verify.sh
bash scripts/swift_build_app.sh release
```

Real-model suites are opt-in and require explicit local model paths:

```bash
CNS_RUN_MODEL_TESTS=1 bash scripts/swift_verify.sh
CNS_RUN_EDITOR_MODEL_TESTS=1 bash scripts/swift_verify.sh
```

## Context routing

Read only the guide and durable context relevant to the task.

| Task area | Read first |
|---|---|
| Native lifecycle, composition, packaging | [ClickNSpeak guide](ClickNSpeak/AGENTS.md), [runtime ownership](docs/architecture/runtime-ownership.md) |
| Swift package boundaries | [Packages guide](Packages/AGENTS.md), then the owning package guide |
| Recording, popup, and delivery | [session guide](Packages/CNSSession/AGENTS.md), [safety invariants](docs/architecture/safety-invariants.md) |
| Dictionary and corrections | [dictionary guide](Packages/CNSDictionary/AGENTS.md) |
| Python compatibility | [src guide](src/AGENTS.md) |
| Build, acceptance, and release | [scripts guide](scripts/AGENTS.md), [verification](docs/operations/verification.md) |
| Tests and parity | [tests guide](tests/AGENTS.md), [verification](docs/operations/verification.md) |
| Agent task boundaries and session metrics | [session policy](docs/operations/agent-session-policy.md) |
| Historical rationale only | `docs/archive/AGENTS-2026-09-24-full-context.md` |

Current code, focused guides, verification runbooks, and tests take precedence
over historical material.
