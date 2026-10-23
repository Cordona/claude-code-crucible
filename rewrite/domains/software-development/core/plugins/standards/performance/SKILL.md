---
name: standard-performance
description: The scaling rubric for code in any language, tests included, that runs on a hot path, loops, or handles large or unbounded data, store access included — a cost model, numbered rules (complexity, N+1, bounded reads, redundant work, data-structure fit, chatty I/O, caching) and a baseline every path meets. Injected into the agent's first message when loaded. Writes nothing. Not for language-level micro-performance (its tech plugin) or a durable store's correctness (standard-persistence).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Performance
---

# Standard: Performance

How code should scale with its input, in any language. The developer builds to these rules, then follows `references/development.md`; a reviewer (once a review flow dispatches `code-reviewer`) judges by the same rules, then follows `references/review.md`. Both receive this file in their prompt (or by Read, implementing directly), with their role's reference file right after it.

## Scope

- **In:** how the logic scales with its input (algorithmic complexity and access patterns), in all code the developer writes or changes, test code included and under the same cost model, wherever it runs on a hot path, loops, or handles large or unbounded data.
- **Store access is in:** every rule applies in full whether or not a durable store is involved, and the developer builds to all of them either way.
- **Project conventions:** follow the project's performance patterns: its batching helpers, its pagination conventions, its cache layer. New code never bypasses an existing safe pattern. A convention never excuses a scaling defect: an unbounded query, an N+1 or an O(n²) hot path is a defect even where the project does the same.

## 1. Cost model

Classify each path first, sensitive or cold: the cost model sets which rules apply to it.

- **Scale sensibly the first time:** the non-dumb choice by default is competent construction, not optimization.
- **A premature micro-optimization is itself a defect (YAGNI):** scale scrutiny to where cost accrues.
- **On a sensitive path (a hot path, a loop whose iteration count grows with input, large or unbounded data, or a latency-sensitive flow), apply Rules 1–7.**
- **On a cold path (every path that is not sensitive, such as a one-shot or rarely run path over small, bounded data), do the simple thing and stop:** never micro-optimize it, and never trade clarity for speculative speed. The baseline still applies.
- **A suspected bottleneck on a path that isn't plainly sensitive: measure before changing it;** never guess.
- **Judge behaviour, not language constructs:** complexity and access patterns decide. A store, client or protocol named below (SQL, HTTP) is an example; map each pattern to the stack in front of you.

## 2. Scaling rules

On a sensitive path. Cited by number.

- **Rule 1, algorithmic complexity:** no nested iteration over related data (O(n²) or worse), no sort or search inside a loop, and no repeated linear scan of the same collection.
- **Rule 2, work per item (N+1):** never issue a query, RPC, HTTP call or expensive computation once per item where one batched call would do. A SQL N+1, an HTTP call in a loop and a cache miss in a loop are the same pattern on any stack. Hoisting invariant work out of a loop is Rule 4.
- **Rule 3, bounded reads:** paginate or limit every unbounded read. No load-all without a limit, no over-wide read (`SELECT *` of huge rows), no whole file or stream read into memory when a slice is needed, and no collection that grows without bound with traffic.
  - **Deep offset pagination over large data is unbounded too:** each page reads past every row before it, so its cost grows with depth. Page by key (keyset or cursor), unless a need keyset can't serve, such as a jump to page N, rules it out.
- **Rule 4, redundant computation:** never recompute an invariant on every iteration; hoist it out of the loop, or memoize identical repeated work.
- **Rule 5, data-structure fit:** use a set or map for membership and dedup, not a linear scan inside a loop (O(n²) becomes O(n)), and no list where random access or dedup is needed.
- **Rule 6, chatty or blocking I/O:** collapse many round-trips into one (batch or pipeline), and no synchronous blocking I/O on a latency-sensitive path that should be async or parallel.
- **Rule 7, caching across calls:** when separate invocations or requests fetch or compute the same expensive result again, cache it. Repeated work within one loop is Rule 4; batching one call's repeated work is Rules 2 and 6.

## 3. Baseline, on every path

- **Every path meets the baseline, cold paths included:** the right data structure for the access pattern, no gratuitous N+1, and bounded reads. It costs nothing in clarity and prevents the most common scaling defects.
- **The build bar is stricter than the review floor:** the developer meets the baseline in full, even where a reviewer would grade a miss lightly, since doing it right the first time costs nothing.

## 4. Clarity and speed

- **Clarity wins by default:** when clarity and an optimization conflict, write the clear version; it needs no comment.
- **Keep an optimization that costs clarity only on a measurably hot path,** with a WHY comment saying why it stays.
