# Source Split Design

## Goal

Keep the native Swift app and the frozen Python implementation as two
self-contained sibling directories in one repository. `swift-app/` is the
only product under active development. `legacy-python/` is a runnable,
maintenance-only rollback reference that can later be extracted intact.

## Layout

```text
Click-n-speak/
├── swift-app/
│   ├── ClickNSpeak/
│   ├── Packages/
│   ├── assets/
│   ├── locales/
│   ├── scripts/
│   ├── tests/
│   ├── design/
│   └── docs/
└── legacy-python/
    ├── main.py
    ├── src/
    ├── tests/
    ├── assets/
    ├── locales/
    ├── scripts/
    ├── design/
    └── docs/
```

The repository root retains only Git metadata, a short workspace README,
root automation, and temporary cross-app CI. Neither application may need
the other directory to build, run its focused tests, or find runtime
resources.

## Ownership

- `swift-app/` owns `ClickNSpeak/`, `Packages/`, native build/release
  scripts, native test fixtures, and all living roadmap/release documents.
- `legacy-python/` owns `main.py`, `src/`, Python application tests,
  py2app packaging, Python dependencies, and legacy operational scripts.
- Runtime PNG/ICNS assets, locale JSON, design material, historical
  migration documents, and configuration-format fixtures are copied to both
  directories. They are snapshots, never symlinks.
- Python files used only to test, benchmark, or package the native app remain
  Swift-owned tooling. Ownership follows purpose, not file extension.

## Compatibility

Both applications retain the existing Application Support paths and data
formats. The separation changes repository paths only. During the rollback
window, cross-app parity is an optional workspace check; it is not a normal
Swift or legacy build dependency.

## Constraints

- Preserve history with `git mv` for the primary copy of moved files.
- Do not move ignored user data, model artifacts, virtual environments,
  `.build/`, `dist/`, or generated vendor binaries.
- Do not introduce symlinks between the sibling applications.
- Do not create a license text: the repository claims MIT in `README.md` but
  has no tracked `LICENSE` file or confirmed copyright notice.
