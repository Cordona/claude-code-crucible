# Performance: review

Apply after `SKILL.md`'s rules when judging code by the performance rules: judge the change by every rule there, then apply these. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

- **A bottleneck the code doesn't show:** ask for a measurement in the finding; never assert a cost you can't show from the code.
- **Flag N+1 only where the code bypasses the framework's eager or batch loading:** that API already makes one batched call, so `SKILL.md` Rule 2 holds.
- **A micro-optimization on a cold path that costs clarity is a finding:** `SKILL.md` counts it a defect. A cold path left simple is none.
- **An optimization kept on a measurably hot path, with its WHY comment, is no clarity finding.**
- **No finding without the concrete scaling harm:** name the input size and how often the code runs.

## Severity

Where a performance defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - none for this lens.
- **HIGH:**
  - O(n²) or worse, or a non-store N+1, on a hot path over large or unbounded data;
  - over-fetch or an unbounded load that scales with data volume (non-store).
- **MEDIUM:**
  - redundant work or the wrong data structure on a hot path;
  - chatty round-trips or blocking I/O to a non-store peer on a latency-sensitive path.
- **LOW:**
  - a missing caching, batching or pagination opportunity;
  - a deviation from the project's performance patterns (bypassing an existing batching helper, pagination convention or cache layer);
  - a baseline-hygiene slip (wrong data structure, gratuitous N+1, unbounded read) on a cold path over small bounded data;
  - a micro-inefficiency on a cold or rarely run path.

**Overrides:**
- A baseline-hygiene slip over trivially small data is no finding.
- A micro-inefficiency on a cold path is usually no finding; a language-level one is outside this plugin.

**What moves a level:**
- Over-fetch and unbounded loads drop to MEDIUM when the data volume or the path makes the cost smaller.
- A missing caching, batching or pagination opportunity, and a pattern deviation, rise to MEDIUM when the path is hot or the data large.
