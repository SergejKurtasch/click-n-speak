### Task 2: Promote the Swift product and retire tracked legacy code

**Files:**
- Move: `swift-app/ClickNSpeak/`, `Packages/`, `assets/`, `locales/`, `design/`,
  active `scripts/`, `docs/`, `spikes/`, and Swift tests to their root ownership.
- Remove from Git: `legacy-python/` and root cross-application Python parity code.
- Modify: root README, AGENTS, CI, Codex rules, active scripts, Swift docs.

**Interfaces:** Produces the root-level SwiftPM layout expected by
`ClickNSpeak/Package.swift` and all release scripts.

- [x] **Step 1: Write failing Swift-only layout checks**

Add a root structural check that requires `ClickNSpeak/Package.swift`,
`Packages/CNSCore/Package.swift`, `assets/`, `locales/`, and
`scripts/swift_verify.sh`, and rejects `legacy-python/` and `swift-app/`.

- [x] **Step 2: Run the check and observe RED**

Run the check before promotion. Expected: it fails because the Swift tree is nested
and the legacy tree exists.

- [x] **Step 3: Promote and prune**

Use `git mv` to promote every active Swift-owned path. Remove the now-archived
legacy tree and cross-app parity/runtime bridge with `git rm`. Update paths in
CI, scripts, tests, guides, and docs. Retain only Swift-owned fixtures; do not
replace a dependency with an archive path.

- [x] **Step 4: Verify GREEN**

Run `bash scripts/swift_verify.sh`, root layout checks, and focused Swift package
tests. If the ignored Whisper binary is absent at its promoted `Packages/...`
location, relocate the user's existing local artifact from the former original
checkout only after the merge decision; otherwise record it as environment setup.

- [x] **Step 5: Commit**

Commit message: `refactor: cut over to Swift-only repository`.
