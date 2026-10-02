# Click-n-speak Swift application guide

The repository root is the active SwiftPM application. `ClickNSpeak/`,
`Packages/`, native resources, release scripts, and focused tests are owned
here. The frozen Python implementation is archived outside Git and must not
be restored as a runtime dependency.

## Ownership

Preserve existing Application Support paths and data formats. See the
[Swift-only cutover specification](docs/superpowers/specs/2026-09-26-swift-only-cutover.md)
for the migration contract.

## Working rules

- Responses and plans: Russian. Code, comments, docstrings, and commits: English.
- Preserve unrelated working-tree changes. Never discard or overwrite them.
- Use conventional commits: `feat:`, `fix:`, `refactor:`, `chore:`, `test:`, `docs:`.
- Never commit secrets, `.env`, runtime transcripts, prompts, clipboard data,
  model artifacts, or user configuration.

## Workspace verification

The repository-contract check runs from the workspace root:

```bash
venv/bin/python -m pytest tests/test_agent_environment.py -q
```

Run the root Swift verification gate with `bash scripts/swift_verify.sh`.
