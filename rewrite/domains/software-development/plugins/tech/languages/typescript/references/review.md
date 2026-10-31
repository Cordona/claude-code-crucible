# TypeScript: review

Apply with `SKILL.md`'s rules when judging TypeScript: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness for TypeScript:** this language plugin, with any framework plugins loaded beside it, judges whether the code does what it is meant to. Check for:
  - a `switch` over a union with no `never` check;
  - a missing narrow, a `?.` that masks a real missing value, or a caught value used as an `Error` unnarrowed;
  - a floating promise or an unhandled rejection;
  - a `==` coercion that changes the result;
  - number precision lost on money, or on ids past `2^53`;
  - off-by-one;
  - boundary and error paths that are incomplete;
  - behaviour that breaks its intended contract.

## How to judge

- **Count a nullability or exhaustiveness defect once, as correctness,** never again as type safety.
- **Don't demand `.strict()` for `.passthrough()` on data the codebase doesn't control:** `SKILL.md`'s Zod rules make that split on purpose.
- **Judge a `.js` file only by the rules JavaScript can express.**
- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.
- **Verify a library API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a TypeScript defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:** none of its own; a HIGH defect reaches it only by What moves a level.
- **HIGH:**
  - a correctness defect from Correctness above;
  - a floating promise or an unhandled rejection;
  - a parsed value that reaches a dangerous sink with no control of its own (a URL scheme, HTML), as `SKILL.md`'s Zod rules set.
- **MEDIUM:**
  - a bare `any` or an unsafe assertion;
  - a Zod schema that departs from `SKILL.md`'s Zod rules other than the boundary parse, outside that sink rule;
  - an unpinned dependency or another supply-chain gap, against `SKILL.md`'s Supply chain mechanism;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - a type-check diagnostic or a lint-discipline lapse;
  - a suppression with no written reason;
  - a naming deviation;
  - micro-performance.

**Overrides:**
- **Test code:** a build diff that changes test code, a test module inside a source file included, is HIGH, as `code-reviewer` sets; no rule here grades test code lower.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- A fail-open check, client-side data exposure and XSS drop to MEDIUM when exploiting them is harder or reaches less.
- A lint-discipline lapse can rise to MEDIUM, judged on the case.
- Micro-performance rises above LOW only on a hot path.
