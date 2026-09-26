# Benchmarking Codex root profiles

This procedure decides whether the root default may change from the deep profile
to the efficient profile. It records task-level aggregates only; it never stores
task text, prompts, transcripts, session content, or credential values.

## Profiles pending external approval

Do not create or edit user configuration as part of this repository procedure.
After explicit approval, create these external templates and verify that both
inherit the validated Luna/medium subagent defaults from the base configuration:

`/Users/sergej/.codex/efficient.config.toml`:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "medium"
```

`/Users/sergej/.codex/deep.config.toml`:

```toml
model = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"
```

Do not modify `/Users/sergej/.codex/config.toml` until acceptance succeeds.

## Frozen paired protocol

1. Record one immutable repository revision with `git rev-parse HEAD`; use that
   exact revision, task fixture, and acceptance expectation for every run.
2. Assert `git status --porcelain` is empty before creating each run side. Use a
   disposable worktree for `efficient` and a separate disposable worktree for
   `deep`, both created at that exact revision. Do not use either profile against
   the developer's working checkout.
3. Run each class once with `efficient` and once with `deep`, without changing
   the worktree revision, dependencies, task fixture, or evaluator between the
   paired runs. Fix a numeric pairing seed before the first run. The comparison
   tool deterministically applies Python `random.Random(seed).shuffle()` to the
   lexicographically sorted ten class identifiers, keeps each pair adjacent,
   and alternates which profile runs first in successive pairs. Record exactly
   that resulting order; the tool rejects an order that does not match its seed.
4. Record only the allowed numeric/boolean fields and the class identifier in
   the aggregate input. Never record task text or any session content.
5. Use exactly these ten classes: `small_bug_diagnosis`, `focused_unit_fix`,
   `swift_concurrency_review`, `python_parity_check`, `config_migration`,
   `test_failure_triage`, `documentation_update`, `release_script_review`,
   `multi_file_refactor_plan`, and `regression_review`.
6. Inspect the deterministic comparison output and preserve only the aggregate
   report where benchmark retention is needed.

## Provenance manifest

The input object has `provenance` and `results` fields only. `provenance` is a
privacy-safe manifest required by the comparison tool; it contains no task text
or fixture contents:

```json
{
  "repository_revision": "<40 lowercase hex Git revision>",
  "working_tree_clean": true,
  "benchmark_version": "1",
  "fixture_sha256": "<64 lowercase hex SHA-256>",
  "acceptance_sha256": "<64 lowercase hex SHA-256>",
  "pairing_seed": 20260924,
  "run_order": ["efficient:small_bug_diagnosis", "deep:small_bug_diagnosis"]
}
```

The benchmark version is the fixed literal `"1"`, not a free-form label. The
two digests identify the frozen task-fixture bundle and acceptance criteria
without retaining their contents. `run_order` must contain every
`profile:task_class` exactly once, keep paired classes adjacent, and alternate
the first profile. The output copies this manifest with aggregate comparison
metrics, so the decision remains reproducible without a transcript.

## Aggregate input schema

The input is a JSON object with only `provenance` and `results`. `results`
contains exactly ten results per profile, one for every representative class.
Each result has exactly these fields:

```json
{
  "profile": "efficient",
  "task_class": "small_bug_diagnosis",
  "completion": true,
  "user_corrections": 0,
  "regressions": 0,
  "wall_time_seconds": 42.5,
  "input_tokens": 1200,
  "output_tokens": 800
}
```

Profiles are `efficient` or `deep`. Counts and tokens are non-negative integers;
completion is a boolean; wall time is a finite non-negative number. Unknown fields anywhere and content-bearing keys,
including `task_text`, `prompt`, `transcript`, and `session_content`, are
rejected.

## Decision

Run:

```bash
venv/bin/python scripts/compare_codex_profiles.py \
  --input /private/tmp/click-n-speak-profile-results.json \
  --output /private/tmp/click-n-speak-profile-comparison.json
```

`promote_efficient` is true only when efficient has at least 9 tasks with `completion: true`,
no more total user corrections than deep, no more total regressions than deep,
and a strictly lower median of `input_tokens + output_tokens`. Median wall time
is reported for context and never independently promotes a profile.

If the result is true, approval is required before changing the base root effort
to `medium`. Otherwise retain `xhigh` and choose `--profile efficient` only for
bounded routine tasks.
