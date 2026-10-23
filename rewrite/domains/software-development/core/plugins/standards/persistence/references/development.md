# Persistence: development

Apply after `SKILL.md`'s rules, before writing code.

## Reporting

`standard-code-development-report` sets each item's shape.

- **The store one-liner, with each choice its guarantees drove** (a saga over a transaction, offset paging kept, a forward-fix in place of a down step) -> the report's `decisions`, because the reviewer reads every rule through the same guarantees, so a wrong one shows there first.

## Self-check before reporting

1. The store and its two or three guarantees were named in one line before writing. Each capability that line denies, or that hangs on a version or edition, was verified.
2. Integrity rules sit at one layer, and invalid state is rejected before it persists. Tombstones are excluded structurally, and prior state the domain needs survives.
3. Each all-or-nothing operation is atomic by the store's mechanism, or idempotent with compensation. No transaction spans a network call, and no write is a cross-store dual-write. Each bulk write and non-atomic multi-step flow defines its partial-failure outcome.
4. Each read-modify-write, work claim and colliding blind write uses the store's concurrency primitive. Locks are ordered and bounded. No isolation or read-your-writes is assumed beyond what the store gives.
5. Each query is served by an index or a modelled access pattern, with each result set held within a memory bound, stable paging and only the fields needed. Connections are pooled and released on every path; large reads are streamed.
6. Each schema change keeps old and new code working, has a known lock and rewrite cost, and ships apart from its backfill and deploy. Writes and consumers are idempotent, and success waits for the durability needed. Destructive operations are guarded, retries bounded, no write error swallowed, and no correctness rests on TTL timing.
7. Values keep the equality the code relies on, exact values are exact, and instants are unambiguous. Referenced keys never change; keys fit the store and can't run out; serialized values evolve compatibly. The project's persistence patterns were followed, and none excused an integrity or lost-update bug.
8. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
