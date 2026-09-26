# Click-n-speak workspace

Click-n-speak is a macOS menu-bar speech-to-text application. This repository
contains two deliberately separated application trees:

- [`swift-app/`](swift-app/README.md) — the production Swift application and
  the only actively developed product.
- [`legacy-python/`](legacy-python/README.md) — the frozen, rollback-only
  Python reference kept for migration and recovery.

The split is a repository layout change. Both applications retain their
existing Application Support paths and on-disk data formats. Each tree must be
able to build, test, and resolve its runtime resources without depending on
the sibling tree. Workspace-level automation and source-split documentation
remain at the repository root.

See the scoped guides in each application directory before making changes:
[`swift-app/AGENTS.md`](swift-app/AGENTS.md) and
[`legacy-python/AGENTS.md`](legacy-python/AGENTS.md).
