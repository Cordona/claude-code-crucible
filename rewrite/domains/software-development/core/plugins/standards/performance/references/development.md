# Performance: development

## Reporting

- **Each optimization kept at clarity's cost:** record it, with the measurement that shows its path is hot, because it is the one place this standard lets speed beat clarity.

## Self-check before reporting

1. Each path you wrote or changed is classified sensitive or cold.
2. On each sensitive path, Rules 1–7 hold.
3. Every path, cold ones included, uses the right data structure for its access pattern, has no gratuitous N+1, and reads only bounded data.
4. No cold path was micro-optimized, and no path that isn't plainly sensitive was optimized without a measurement.
5. Each optimization kept at clarity's cost sits on a measurably hot path, and has a WHY comment.
6. The project's batching, pagination and caching patterns were followed, and none excused an unbounded read, an N+1 or an O(n²) hot path.
