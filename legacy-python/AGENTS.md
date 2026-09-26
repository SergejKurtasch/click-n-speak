# Legacy Python guide

This directory is a frozen rollback-only application tree. It owns the
legacy Python entry point, `src/`, Python tests, packaging metadata, runtime
resources, and legacy scripts.

Keep imports, resource lookup, and packaging relative to `legacy-python/`.
Never make the legacy runtime depend on `swift-app/`, repository-root source,
or a symlink to the native tree. New behavior belongs in `swift-app/`; any
maintenance change here must preserve rollback behavior and be documented in
`LEGACY_STATUS.md`.
