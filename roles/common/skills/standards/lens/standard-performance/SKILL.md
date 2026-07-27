---
name: standard-performance
description: The single definition of performant, well-scaling code — the shared rubric that developers BUILD to (baseline performance hygiene) and the performance lens REVIEWS against (algorithmic & access-pattern scaling). Applies whenever logic runs on a hot path, iterates, or handles large/unbounded data in any language. Defines the performance-sensitivity principle (scale scrutiny to where cost accrues; no premature optimization), algorithmic complexity, N+1 / work-in-loop, over-fetch / unbounded data, redundant computation, data-structure fit, chatty/blocking I/O, and caching/batching. This is WHAT good looks like; it does not define builder workflow (build-core), the reviewer's sensitivity gate procedure / severity / vocabulary (the lens), or language micro-performance (the {tech} pair).
---

# Standard: Performance

The **one** definition of code that scales sanely. Developers build to it by default (performance hygiene); the `lens-performance-reviewer` judges how a change scales. Both bind this single skill, so there is no daylight between how we build and how we review.

This skill defines **WHAT good looks like**. It does NOT contain: the builder's workflow (`build-core`); the reviewer's machinery (the Phase-0 sensitivity-gate *procedure*, severity, `category` vocabulary, "require the concrete scaling harm" discipline — those live in the lens); or **language micro-performance** (a clone, a boxing allocation, GC tuning — the `{tech}` developer/reviewer).

## Philosophy: scale sanely by default, don't optimize prematurely

Write code that scales sanely the first time — this is **competent construction, not optimization**. Do the non-dumb thing by default. But **premature micro-optimization is itself a defect** (YAGNI): scale scrutiny to where cost actually accrues.

**Where cost accrues (apply the scaling rules below):** a **hot path** (per-request/message/frame or high-frequency) · **inside a loop** whose iteration count grows with input · over **large or unbounded data** · a **latency-sensitive** flow.

**Where it does not** (a one-shot or rarely-run path over small bounded data): do the simple thing and stop — do NOT micro-optimize a cold path or trade clarity for speculative speed. If a real bottleneck is suspected on a non-obvious path, **measure first**; don't guess.

## The scaling rules

Reason about the code's **behavior** (complexity and access patterns), not language constructs. Runtime names (Postgres, Hibernate, Redis, gRPC…) are illustrative — map each pattern to the target's stack.

1. **Algorithmic complexity** — no nested iteration over related data (O(n²)+), no sort/search *inside* a loop, no repeated linear scans of the same collection on a sensitive path.
2. **N+1 / work-in-loop** — never issue a query / RPC / HTTP call / expensive computation **once per item** where a single batched call would do. Hoist invariant work out of loops. (SQL N+1, HTTP-in-loop, cache-miss-in-loop — same pattern, any stack.)
3. **Over-fetch / unbounded** — paginate or limit unbounded reads; no load-all without a limit, no over-wide reads (`SELECT *` of huge rows), no reading a whole file/stream into memory when you need a slice, no collection that grows unbounded with traffic.
4. **Redundant computation** — don't recompute an invariant every iteration; memoize or hoist identical repeated work out of the loop.
5. **Data-structure fit** — use the right structure for the access pattern: a set/map for membership or dedup, not a linear scan inside a loop (turns O(n²) into O(n)); not a list where random access / dedup is needed.
6. **Chatty / blocking I/O** — collapse many round-trips into one (batch/pipeline); don't do synchronous blocking I/O on a latency-sensitive path that should be async/parallel.
7. **Caching / batching** — cache or batch the same expensive result where it is fetched/computed repeatedly and that is the standard fix.

## Baseline hygiene (the build-to minimum)

Even off a hot path, do the non-dumb thing the first time: the **right data structure** for the access pattern, **no gratuitous N+1**, and **bounded** reads. That baseline costs nothing in clarity and prevents the most common scaling defects.

## Boundary with language micro-performance

This standard owns **algorithmic and access-pattern** scaling — how the *logic* scales with input. Language-level micro-performance (allocation, boxing, `clone`, GC tuning) is the `{tech}` developer/reviewer's call, not this standard's. When clarity and a genuine hot-path optimization conflict, prefer clarity and leave a WHY comment — unless the path is measurably hot.

---
*Standard Version: 1.0 — the shared performance rubric. Built to by developers (via build-core); reviewed against by lens-performance-reviewer. Language micro-perf lives in the {tech} pair.*
