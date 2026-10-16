# Observability: review

Apply after `SKILL.md`'s rules when judging code by the observability rules: judge the change by every rule there, then apply these. This file holds only how to judge a finding; it sets no category vocabulary or severity mapping.

- **Name the codebase's shape before flagging a missing pillar:** a pillar its row in `SKILL.md` Pillars by shape doesn't need is no finding; one forced onto a library or CLI is.
- **A pure function or trivial helper with no telemetry is no finding** (`SKILL.md` Pillars by shape).
