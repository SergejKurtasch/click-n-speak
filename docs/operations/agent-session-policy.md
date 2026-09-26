# Agent session boundary policy

Use a new root task when the objective changes. Keep each task focused on one
objective so its context and verification remain attributable.

For an independent subagent, set `fork_turns: "none"` and provide a
self-contained task description. When recent conversation is genuinely
required, use the smallest sufficient positive fork count instead of copying
unrelated context.

After two compactions on one objective, write a concise handoff checkpoint and
continue in a fresh task. The checkpoint may contain only the current goal,
completed work, verification evidence, and the next safe action; it must not
copy transcripts, commands, tool output, credentials, or user content.

Do not spawn a subagent for one dependent command or for work shorter than the
coordination overhead. Run that bounded step in the current task.

## Fourteen-day audit contract

Each generated audit report identifies its half-open UTC window with
`window_start` and `window_end`: records at the start are included and records
at the end are excluded. The report's `approval_events` value is the number of
observed approval lifecycle records (`approval`, `approval_requested`, or
`approval_resolved`) with a recognized approval status. It is not a count of
unique approval prompts, because rollout metadata has no durable request ID.

`input_tokens` is the sum of the largest `total_token_usage.input_tokens`
snapshot observed in each rollout JSONL file during the window. That counter is
cumulative within a rollout, so summing individual snapshots would overcount.
For an older rollout schema that has no `total_token_usage` field anywhere in a
file, the audit falls back to the largest `last_token_usage.input_tokens` value.
It never uses a last-turn value to replace a present total counter.
`model_effort_distribution` counts valid `(model, effort)` pairs in
`turn_context` records, not task starts or completed turns; it is an observation
distribution for the selected window.

Reports must be written outside the repository. To compare two existing reports
without reopening session JSONL, use two non-overlapping 14-day windows:

```bash
venv/bin/python scripts/audit_codex_sessions.py \
  --compare-reports /private/tmp/click-n-speak-codex-baseline.json /private/tmp/click-n-speak-codex-comparison.json \
  --output /private/tmp/click-n-speak-codex-report-comparison.json
```

The comparison contains aggregate reductions and per-root-turn compaction
rates. It does not infer a median initial-prompt token count or completed-task
rate, because those measurements are absent from the aggregate schema.
