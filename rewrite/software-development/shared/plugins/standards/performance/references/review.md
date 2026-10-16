# Performance: review

Apply after `SKILL.md`'s rules when judging code by the performance rules: judge the change by every rule there, then apply these. This file holds only how to judge a finding; it sets no category vocabulary or severity mapping.

- **A bottleneck the code doesn't show:** ask for a measurement in the finding; never assert a cost you can't show from the code.
- **Flag N+1 only where the code bypasses the framework's eager or batch loading:** that API already makes one batched call, so `SKILL.md` Rule 2 holds.
- **A micro-optimization on a cold path that costs clarity is a finding:** `SKILL.md` counts it a defect. A cold path left simple is none.
- **An optimization kept on a measurably hot path, with its WHY comment, is no clarity finding.**
