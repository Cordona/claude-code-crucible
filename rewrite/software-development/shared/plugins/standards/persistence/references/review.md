# Persistence: review

Apply after `SKILL.md`'s rules when judging code by the persistence rules: judge the change by every rule there, then apply these. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

- **Flag offset paging only on large or changing data:** where `SKILL.md` §4 "Page stably" keeps offset correct, it is no finding.
- **Flag a stale read only past the task's consistency need:** a store read that misses a just-committed write (eventual consistency, replica lag), or an application or read-model cache serving a value older than the need allows. Staleness the need allows is no finding.
- **A single-item write needs no transaction:** never demand one.
- **A single-node store:** never demand durable replication; flag durability only where the store lets it be tuned and the loss matters.
- **An additive column with a constant default is a metadata-only change** on stores that do it that way: never apply the old full-rewrite rule to it.
- **Flag N+1 only where the code bypasses the safe batch or eager-loading API.**
- **A read-only query change:** atomicity and idempotency don't apply.
- **A purely additive, nullable change needs no expand-contract:** never demand one.

## Severity

Where a persistence defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - data corruption or loss: a non-atomic multi-write with no compensation, broken referential integrity, a lost update on a read-modify-write, a destructive in-place update that erases required prior state;
  - a cross-store dual write with no outbox or reconcile; write skew on a cross-row invariant; a blind write that silently drops data on a last-write-wins store;
  - an acknowledged write that can be lost on failover (durability below what the operation needs); a destructive or irreversible operation (unpredicated `DELETE`, `TRUNCATE`, `DROP`, an unbounded rewrite) with no guard or recovery path.
- **HIGH:**
  - a migration that breaks running code mid-rollout (no expand-contract, no tolerant reader); one that locks or rewrites large data and blocks writes; an unthrottled full-collection rewrite on a schemaless store;
  - a bounded 32-bit key or sequence with no widening plan (writes halt at overflow);
  - a non-idempotent write under at-least-once retry, or a check-then-write dedupe with a race window; a work-claim race (two workers process the same item); a non-idempotent consumer; isolation assumed stronger than configured;
  - a soft-deleted row leaking into a live read or colliding with a unique constraint; money stored as a binary float or JSON number; a mutable key other records reference; a non-atomic bulk write left partly applied and unhandled;
  - a uniqueness or lookup check that assumes an equality the store enforces differently (collation, normalisation, null versus absent); a removed or renamed serialized variant that crashes on reading an old row.
- **MEDIUM:**
  - locks taken in inconsistent order (deadlock under contention); an unbounded lock or statement wait;
  - a stale read, where a just-committed write must be visible, that feeds a decision;
  - a transaction held across a network or user wait; an unhandled partial failure in a multi-step flow; a retry loop with no bound or backoff;
  - a required query with no supporting index, table or view on a join-less store; a naive local timestamp where ordering or time-window queries need the instant; relying on TTL timing for correctness;
  - an unbounded result set, a full scan on a hot path, or an N+1 on a real path;
  - naive offset pagination on large or changing data; a missing projection on a hot read;
  - a connection or cursor not released on the error path.
- **LOW:**
  - defence-in-depth or lower-impact hardening (a belt-and-braces constraint).

**Overrides:**
- none for this lens.

**What moves a level:**
- The CRITICAL cases drop to HIGH when less data is at risk or recovery is possible.
- The idempotency, isolation, soft-delete, exact-value, mutable-key, partial-bulk, equality and serialized-variant cases drop to MEDIUM when the damage is smaller or rarer.
- Lock order and lock waits rise to HIGH by contention.
- A stale read rises to HIGH by the impact of the decision it feeds.
- A transaction held across a wait, a partial failure and an unbounded retry rise to HIGH by hold time and call rate.
- A missing index or access pattern, a naive timestamp and TTL reliance rise to HIGH by path.
- Unbounded results, full scans and N+1 rise to HIGH by data size and path.
- A leaked connection or cursor rises to HIGH by call rate.
