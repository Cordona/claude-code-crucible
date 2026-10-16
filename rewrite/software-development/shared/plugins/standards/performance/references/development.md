# Performance: development

Apply after `SKILL.md`'s rules, before writing code.

## Reporting

- **Name each optimization kept at clarity's cost** in the report's Key decisions field, with the measurement that shows its path is hot: it is the one place this standard lets speed beat clarity, and the reviewer judges it by that evidence. Example: `Kept the precomputed price index in quote(): it runs per request and a profile showed the scan at 40% of p99; costs a second structure to keep in sync.`

## Self-check before reporting

1. Each path you wrote or changed is classified sensitive or cold.
2. On each sensitive path, Rules 1–7 hold: no nested scan, sort or search in a loop; no call per item; every read bounded, deep offset paging included; no invariant recomputed in a loop; a set or map for membership; round-trips collapsed; a result fetched again across calls cached.
3. Every path, cold ones included, uses the right data structure for its access pattern, has no gratuitous N+1, and reads only bounded data.
4. No cold path was micro-optimized, and no path that isn't plainly sensitive was optimized without a measurement.
5. Each optimization kept at clarity's cost sits on a measurably hot path, has a WHY comment, and is in Key decisions.
6. The project's batching, pagination and caching patterns were followed, and none excused an unbounded read, an N+1 or an O(n²) hot path.

A failed item: fix it, then run the check again.
