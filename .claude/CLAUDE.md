# CLAUDE

@~/AGENTS.md

## Subagent model selection

- Simple, read-only lookups (find a file, grep a symbol, check if something exists) → default to **Haiku**.
- Multi-step reasoning, planning, code review, writing/editing code → default (do not downgrade).
- **Forks are the exception**: `subagent_type: "fork"` always inherits the parent's model — a `model` override is ignored, so a fork can never be downgraded to Haiku. The Haiku default above only applies to fresh subagents (e.g. `Explore`, `general-purpose`).
