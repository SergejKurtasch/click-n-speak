# Task 2 report: Promote the Swift product and retire tracked legacy code

## RED

Added `tests/test_swift_only_layout.py` before promotion. The structural check
failed as expected because `ClickNSpeak/`, `Packages/`, and Swift resources
were still nested under `swift-app/`, while tracked `legacy-python/` remained.

```text
1 failed
```

## Implementation

- Promoted `ClickNSpeak/`, `Packages/`, `assets/`, `locales/`, `design/`,
  `spikes/`, Swift scripts, Swift docs, and Swift tests to repository root
  using `git mv`.
- Removed tracked `legacy-python/` after the approved external archive was
  confirmed by Task 1.
- Removed root cross-application parity bridge/helper and Python parity
  contract test; retained Swift-owned parity fixtures and Swift tests.
- Updated root README, AGENTS, CI, Codex rules, validation scripts, layout
  checks, and root-relative parity test paths.

## GREEN

```text
tests/test_swift_only_layout.py tests/test_agent_environment.py: 20 passed
bash scripts/verify_layout.sh: passed
swift test --disable-index-store --package-path Packages/CNSCore: 115 tests passed
```

The first Swift invocation encountered stale ignored `.build` module-cache
paths from `swift-app/`; cleaning generated build artifacts and rerunning with
the required Xcode cache access passed.

## Commit

Commit: `c2639b2` (`refactor: cut over to Swift-only repository`)

## Fix round 1

- Removed the four tracked legacy-dependent spike scripts; preserved copies
  remain in the approved external archive.
- Converted the acceptance manifest and validator from Python parity fields to
  Swift behavioral expectation fields while preserving scenario IDs, release
  gates, and Swift test targets.
- Added structural coverage for legacy imports and archive-path dependencies.
- Replaced the active migration plan with a root-relative Swift-only guide and
  retained the former plan under `docs/archive/`.
- Updated verification guidance to use the root Swift commands.

RED was observed when the new structural checks found the four legacy spike
scripts and the old Python-referenced manifest schema. GREEN was observed after
the removals and schema/documentation updates.

Validation for this fix round:

```text
/Users/sergej/Click-n-speak/venv/bin/python -m pytest tests/test_swift_only_layout.py tests/test_agent_environment.py -q
22 passed
bash scripts/swift_verify.sh
Swift verification passed
```

## Final review fix

- Reframed the rollback scenario as Swift configuration migration with
  unknown-key preservation through a Swift round-trip.
- Updated the active release go/no-go template to use current Swift migration
  evidence and removed the Python reload requirement.
- Restored the exact `testFileTypesMatchPythonPickerAndCredentialValidationIsProviderSpecific`
  evidence identifier and added focused manifest assertions.

Final review validation:

```text
/Users/sergej/Click-n-speak/venv/bin/python -m pytest tests/test_swift_only_layout.py -q
3 passed
/Users/sergej/Click-n-speak/venv/bin/python scripts/swift_acceptance.py --validate-only
Validated 60 parity scenarios
bash scripts/swift_verify.sh
Swift verification passed
```

## Task 3 fix round 2

- Moved the Python-specific cutover runbook to `docs/archive/`.
- Replaced the active release runbook with Swift-only rollout and rollback
  guidance targeting the previous signed Swift release.
- Added an explicit link from the active guide to the historical context.

Validation:

```text
/Users/sergej/Click-n-speak/venv/bin/python -m pytest tests/test_swift_only_layout.py -q
3 passed
active runbook Python-reference scan: passed
```

## Risks

- Full `scripts/swift_verify.sh` is still required for release-level coverage.
- The local ignored `legacy-python/` directory may remain with user config and
  caches, but `git ls-files legacy-python` is empty and no runtime is tracked.
