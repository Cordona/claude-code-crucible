---
name: standard-performance
description: The single rubric for performant, well-scaling code (algorithmic complexity, N+1/work-in-loop, over-fetch, data-structure fit, chatty I/O, caching) — built to by developers and reviewed against by the performance lens. Applies whenever code runs on a hot path, loops, or handles large/unbounded data, store access included. Does NOT define builder workflow (build-core), the lens's own sensitivity-gate procedure/category vocabulary/"require the concrete scaling harm" discipline (genuinely lens-performance-reviewer's own), the base severity scale/false-positive discipline (review-core / review-report-standards), language-level micro-performance (the `{tech}` pair), or which lens scores a store-side finding in a review swarm (review-boundaries / standard-persistence).
---

# Standard: Performance

The **one** definition of code that scales sanely. Developers build to it by default (performance hygiene); the `lens-performance-reviewer` judges how a change scales. Both bind this single skill, so there is no daylight between how we build and how we review.

This skill defines **WHAT good looks like**. It does NOT contain: the builder's workflow (`build-core`); the lens's own Phase-0 sensitivity-gate *procedure*, `category` vocabulary, and "require the concrete scaling harm" discipline (genuinely `lens-performance-reviewer`'s own); the base severity scale and universal false-positive discipline (`review-core` / `review-report-standards` — the lens only maps its own categories onto that scale); **language micro-performance** (a clone, a boxing allocation, GC tuning — the `{tech}` developer/reviewer); or which lens scores a store-side finding in a review swarm (`review-boundaries` / `standard-persistence` — see the routing section below).

## Think in cost (the model): scale sanely by default, don't optimize prematurely

Write code that scales sanely the first time — this is **competent construction, not optimization**. Do the non-dumb thing by default. But **premature micro-optimization is itself a defect** (YAGNI — You Aren't Gonna Need It): scale scrutiny to where cost actually accrues.

**Where cost accrues (apply the scaling rules below):** a **hot path** (per-request/message/frame or high-frequency) · **inside a loop** whose iteration count grows with input · over **large or unbounded data** · a **latency-sensitive** flow.

**Where it does not** (a one-shot or rarely-run path over small bounded data): do the simple thing and stop — do NOT micro-optimize a cold path or trade clarity for speculative speed. If a real bottleneck is suspected on a non-obvious path, **measure first**; don't guess.

## The scaling rules

Reason about the code's **behavior** (complexity and access patterns), not language constructs. Runtime names (Postgres, Hibernate, Redis, gRPC…) are illustrative — map each pattern to the target's stack.

1. **Algorithmic complexity** — no nested iteration over related data (O(n²)+), no sort/search *inside* a loop, no repeated linear scans of the same collection on a sensitive path.
2. **N+1 / work-in-loop** — never issue a query / RPC / HTTP call / expensive computation **once per item** where a single batched call would do. (SQL N+1, HTTP-in-loop, cache-miss-in-loop — same pattern, any stack; hoisting the invariant work itself is Rule 4 below.)
3. **Over-fetch / unbounded** — paginate or limit unbounded reads; no load-all without a limit, no over-wide reads (`SELECT *` of huge rows), no reading a whole file/stream into memory when you need a slice, no collection that grows unbounded with traffic.
4. **Redundant computation** — don't recompute an invariant every iteration; memoize or hoist identical repeated work out of the loop.
5. **Data-structure fit** — use the right structure for the access pattern: a set/map for membership or dedup, not a linear scan inside a loop (turns O(n²) into O(n)); not a list where random access / dedup is needed.
6. **Chatty / blocking I/O** — collapse many round-trips into one (batch/pipeline); don't do synchronous blocking I/O on a latency-sensitive path that should be async/parallel.
7. **Caching across calls** — when the same expensive result is fetched/computed repeatedly **across separate invocations/requests** (not just within one loop — that's Rule 4), cache it. Batching a single call's own repeated work is Rules 2/6, not restated here.

## Baseline hygiene (the build-to minimum)

Even off a hot path, do the non-dumb thing the first time: the **right data structure** for the access pattern, **no gratuitous N+1**, and **bounded** reads. That baseline costs nothing in clarity and prevents the most common scaling defects. At review, a baseline violation over small bounded data warrants at most this scale's lowest tier (or no finding at all when the data is trivially small — see `lens-performance-reviewer`'s own severity table for the exact grade, scored against `review-report-standards`'s tiers) — the build-to bar is stricter than the review floor precisely because it costs nothing to just do it right the first time.

## Boundary with language micro-performance

This standard owns **algorithmic and access-pattern** scaling — how the *logic* scales with input; the language-level exclusion is stated above. When clarity and a genuine hot-path optimization conflict, prefer clarity and leave a WHY comment — unless the path is measurably hot.

## Reviewer routing for a store-side finding

The rules above apply in full whether or not a durable store is involved — developers build to all of them either way. In a review swarm, a finding against a durable store routes to `lens-persistence` instead of `lens-performance` — see `review-boundaries` for the exact territory split and its rationale, not restated here.

## Performance consistency

Conform to the project's established performance patterns (batching helpers, existing pagination conventions, an established cache layer) — new code should not bypass an existing safe pattern. But a genuinely unbounded query, N+1, or O(n²) hot path is a defect regardless of project convention; conformance never launders it.
