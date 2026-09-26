# Codex source inventory

Inventory date: 2026-09-25. The audit stores only source paths, skill names,
and SHA-256 digests; it never stores instruction bodies, configuration values,
or environment values.

## Skill sources

The command below produced 42 named skill records. The generated JSON is
ephemeral and was written outside the repository.

```bash
venv/bin/python scripts/audit_codex_sources.py \
  --skill-root /Users/sergej/.codex/skills \
  --skill-root /Users/sergej/.agents/skills \
  --output /private/tmp/click-n-speak-skill-inventory.json
```

The following duplicated names have identical digests. Retain the first,
system-preferred `/Users/sergej/.codex/skills` source for each entry; disable
the second `/Users/sergej/.agents/skills` source through `skills.config` after
the external configuration change is approved. Do not delete either directory.
The physical inventory continues to list disabled sources for review; strict
mode checks only enabled sources.

| Name | Canonical source | Digest | Redundant source |
| --- | --- | --- | --- |
| agents-sdk | `/Users/sergej/.codex/skills/agents-sdk/SKILL.md` | `a05244d3cfb23330daff956ec28a990241f5dbbe489cd7fd6489c8f76bb60877` | `/Users/sergej/.agents/skills/agents-sdk/SKILL.md` |
| cloudflare-email-service | `/Users/sergej/.codex/skills/cloudflare-email-service/SKILL.md` | `a62531900a08f9f6c352061d42e8b10a35009f5e1c6f91bbf18752feedad5a79` | `/Users/sergej/.agents/skills/cloudflare-email-service/SKILL.md` |
| cloudflare | `/Users/sergej/.codex/skills/cloudflare/SKILL.md` | `99be50a67ea1dbae086af3f2bac668c38dd57f71b25ed11f754827a7f206a89d` | `/Users/sergej/.agents/skills/cloudflare/SKILL.md` |
| durable-objects | `/Users/sergej/.codex/skills/durable-objects/SKILL.md` | `cd6797cb18f3ae8f721dfd2e5cb27b73a0aa8636683f1a38163dab2fd51a8dfb` | `/Users/sergej/.agents/skills/durable-objects/SKILL.md` |
| sandbox-sdk | `/Users/sergej/.codex/skills/sandbox-sdk/SKILL.md` | `0f3501e6510921401be3f54bcb24d2a432a1b5c63af8f719eded3a087ad88ea9` | `/Users/sergej/.agents/skills/sandbox-sdk/SKILL.md` |
| turnstile-spin | `/Users/sergej/.codex/skills/turnstile-spin/SKILL.md` | `ffe03a2e63afba7dcc05b0bf7c6c9f9c1c979e56263cede545a581fa87d66488` | `/Users/sergej/.agents/skills/turnstile-spin/SKILL.md` |
| web-perf | `/Users/sergej/.codex/skills/web-perf/SKILL.md` | `94c5cb37766676a8321a82861d2ac1072d3dd0ef612f0c946792014ad48fb0c2` | `/Users/sergej/.agents/skills/web-perf/SKILL.md` |
| workers-best-practices | `/Users/sergej/.codex/skills/workers-best-practices/SKILL.md` | `099432ff265ff6080327ef0b392c118b835d2a5bda98a7de07e1afd115ed6458` | `/Users/sergej/.agents/skills/workers-best-practices/SKILL.md` |
| wrangler | `/Users/sergej/.codex/skills/wrangler/SKILL.md` | `42abe11ba6c0cb0c135deed1d591d844838fe0b61fc8c6d675a832435508a61b` | `/Users/sergej/.agents/skills/wrangler/SKILL.md` |

## Instruction ownership

| Source | SHA-256 digest | Decision |
| --- | --- | --- |
| `/Users/sergej/.codex/AGENTS.md` | `2f79c70987ab9911778dd83a160b6ca631233b4ef3289dda969911a6fe62ee27` | Canonical global guide candidate; unchanged. |
| `/Users/sergej/AGENTS.md` | `2381543a5acee0b4ffced0dc2a8a0a201373025ae1a71eb4c3ed8abb5d3d0e64` | Parent source pending approval; unchanged. |
| `.agents/skills/update-codex-md/SKILL.md` | repository-tracked | Canonical Codex skill. |
| `.claude/skills/update-claude-md/SKILL.md` | repository-tracked | Canonical Claude-owned guide skill. |
| `.cursor/skills/update-claude-md/SKILL.md` | repository-tracked | Thin delegation wrapper. |

## Pending external approval

1. Edit only `/Users/sergej/.codex/config.toml` to add one
   `skills.config` array entry per redundant skill folder above, each with its
   exact folder `path` and `enabled = false`. No skill directory should be
   removed. Verify with the explicit config path:

   ```bash
   venv/bin/python scripts/audit_codex_sources.py --strict \
     --config-path /Users/sergej/.codex/config.toml
   ```
2. Safely compare the two external guide digests above, copy only unique
   durable rules from `/Users/sergej/AGENTS.md` into
   `/Users/sergej/.codex/AGENTS.md`, create an external backup of the parent
   guide, and remove that parent guide only after a fresh prompt shows one
   global block and one project block.

The strict audit intentionally remains red until both approved external actions
are complete. It applies `skills.config` to determine enabled sources and
reports names and paths only.
