# Performance: development

Apply after `SKILL.md`'s rules, before writing code.

## Reporting

`standard-code-development-report` sets each item's shape.

- **Each optimization kept at clarity's cost, with the measurement that shows its path is hot** -> the report's `decisions`, because it is the one place this standard lets speed beat clarity, and the reviewer judges it by that evidence.

## Self-check before reporting

1. Each path you wrote or changed is classified sensitive or cold.
2. On each sensitive path, Rules 1–7 hold: no nested scan, sort or search in a loop; no call per item; every read bounded, deep offset paging included; no invariant recomputed in a loop; a set or map for membership; round-trips collapsed; a result fetched again across calls cached.
3. Every path, cold ones included, uses the right data structure for its access pattern, has no gratuitous N+1, and reads only bounded data.
4. No cold path was micro-optimized, and no path that isn't plainly sensitive was optimized without a measurement.
5. Each optimization kept at clarity's cost sits on a measurably hot path, and has a WHY comment.
6. The project's batching, pagination and caching patterns were followed, and none excused an unbounded read, an N+1 or an O(n²) hot path.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
