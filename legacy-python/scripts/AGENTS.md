# Legacy Python scripts guide

These utilities belong to the frozen Python application. Keep build, packaging,
resource, and maintenance paths relative to `legacy-python/`; do not add
dependencies on `swift-app/` or the workspace root. New production tooling
belongs under `swift-app/scripts/`.
