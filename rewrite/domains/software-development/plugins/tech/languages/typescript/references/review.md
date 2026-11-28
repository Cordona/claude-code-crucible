# TypeScript: review

## Correctness

- **Check for these TypeScript correctness defects:**
  - a `switch` over a union with no `never` check;
  - a missing narrow, a `?.` that masks a real missing value, or a caught value used as an `Error` unnarrowed;
  - a floating promise or an unhandled rejection;
  - a `==` coercion that changes the result;
  - number precision lost on money, or on ids past `2^53`.

## How to judge

- **Count a nullability or exhaustiveness defect once, as correctness,** never again as type safety.
- **Don't demand `.strict()` for `.passthrough()` on data the codebase doesn't control:** the Zod rules make that split on purpose.
- **Judge a `.js` file only by the rules JavaScript can express.**
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.

## Severity

- **CRITICAL:** none of its own; a HIGH defect reaches it only by What moves a level.
- **HIGH:**
  - a parsed value that reaches a dangerous sink with no control of its own (a URL scheme, HTML), as the Zod rules set.
- **MEDIUM:**
  - a bare `any` or an unsafe assertion;
  - a Zod schema that departs from the Zod rules other than the boundary parse, outside that sink rule;
  - an unpinned dependency or another supply-chain gap, against the Supply chain mechanism;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - a type-check diagnostic or a lint-discipline lapse;
  - a suppression with no written reason;
  - a naming deviation;
  - micro-performance.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- A lint-discipline lapse can rise to MEDIUM, judged on the case.
- Micro-performance rises above LOW only on a hot path.
