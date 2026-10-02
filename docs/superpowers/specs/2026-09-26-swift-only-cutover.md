# Swift-only cutover specification

## Goal

Make the Git repository a Swift-only Click-n-speak project. Preserve the frozen
Python implementation outside Git at `/Users/sergej/Click-n-speak-python-legacy-archive`.

## Required end state

- The archive is a byte-preserving copy of the completed `legacy-python/` tree,
  made before its tracked copy is removed.
- Git contains no `legacy-python/` application, Python runtime, Python package
  metadata, legacy assets, or legacy tests.
- The active Swift tree is promoted from `swift-app/` to the repository root:
  `ClickNSpeak/`, `Packages/`, `assets/`, `locales/`, `design/`, and active
  Swift scripts/docs/spikes use their conventional root-relative locations.
- Swift package paths, CI, project guides, and release scripts work at the
  promoted root.
- Cross-application parity artifacts are retired from the Git repository; the
  Swift-owned configuration fixtures and Swift tests remain.
- Developer/CI utilities that support the Swift project may remain even when
  written in Python, but they must not import or invoke archived Python runtime
  code. They are tooling, not a second application.
- No repository action publishes, pushes, or deletes the external archive
  without the user's explicit authorization.

## Safety

- Do not overwrite an existing archive directory.
- Do not include ignored user configuration, model files, environments, caches,
  or build output in the archive.
- Preserve user data paths and app data formats.
