# Swift application guide

This directory is the active production tree. Keep native source, packages,
resources, tests, release tooling, and current native documentation here.

Use SwiftPM commands from `swift-app/`; preserve the sibling relationship
between `ClickNSpeak/` and `Packages/`. Runtime paths and test fixtures must be
derived from this tree and must not depend on `legacy-python/`.

The Python application is a frozen rollback reference. Cross-application
parity checks may be workspace checks, but they are not Swift build or test
dependencies.
