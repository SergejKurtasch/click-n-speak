# Click-n-speak workspace guide

The repository root is a workspace map and owns only cross-application
automation and documentation. Application source, runtime resources, tests,
and build tooling belong to one of the two sibling trees below.

## Ownership

- [`swift-app/`](swift-app/AGENTS.md) is the production Swift application and
  the only actively developed product.
- [`legacy-python/`](legacy-python/AGENTS.md) is the frozen, rollback-only
  Python application.

The two trees must remain independently buildable and relocatable. Do not add
runtime symlinks or mandatory `../` lookups between them. Preserve existing
Application Support paths and data formats. See the [source split design](docs/superpowers/specs/2026-09-26-source-split-design.md)
and [implementation plan](docs/superpowers/plans/2026-09-26-source-split.md)
for the staged migration contract.

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

Application build and test commands are intentionally documented in the
scoped guides and run from their owning roots: [`swift-app/AGENTS.md`](swift-app/AGENTS.md)
and [`legacy-python/AGENTS.md`](legacy-python/AGENTS.md). Root automation and
source-split checks are workspace concerns; application behavior belongs in
the owning tree.
