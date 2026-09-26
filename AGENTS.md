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

Scoped guides define commands relative to their application roots. Root CI and
source-split checks are workspace concerns; application behavior belongs in
the owning tree.
