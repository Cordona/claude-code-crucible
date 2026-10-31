# React: review

Apply with `SKILL.md`'s rules when judging React code, beside the language plugin's review rules: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness, and with this plugin loaded it judges React correctness too.** Check for:
  - a Rules of Hooks break;
  - an effect with a missing dependency or derived state;
  - a stale closure, an `async` effect callback, or a literal in a dependency array;
  - an async race with no cancellation;
  - an index key on a list that changes;
  - an input both controlled and uncontrolled;
  - an unhandled loading, empty or error state;
  - `useState(prop)` expected to resync;
  - a hydration mismatch or SSR-unsafe access;
  - server-only code crossing into a client component.

## How to judge

- **Never flag a conditional `use()`:** it is no Rules of Hooks break.
- **With the React Compiler on, never require manual memoization:** the compiler memoizes.
- **File a missing memo only on a proven bottleneck:** a memo added on a guess costs readability for no measured gain.
- A secret written in the diff is a `found` item, as `code-reviewer` sets, never a finding of this lens.
- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.
- **Verify a React API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a React defect usually lands on the four levels. Start here, then judge the case in front of you. It places React defects, its security and accessibility forms included; the language plugin's Severity grades the language rules.

- **CRITICAL:** none of its own; a HIGH defect reaches it only by What moves a level.
- **HIGH:**
  - a correctness defect from Correctness above;
  - server data kept in `useState`;
  - an unsanitized `dangerouslySetInnerHTML`, or a supplied `href` or `src` with an unchecked scheme;
  - a secret or token read into client-bundled code, `localStorage` or `sessionStorage`;
  - a label or `aria-*` reference that doesn't resolve to one element (`for` in place of `htmlFor`, an id not from `useId` that repeats and that a label or an `aria-*` reference points at);
  - a raw `ZodError` shown instead of an error tied to its field.
- **MEDIUM:**
  - missing effect cleanup;
  - an id not from `useId` that repeats and that no label or `aria-*` reference points at;
  - a `react-hooks` or `jsx-a11y` rule turned off or down in the project's lint config.
- **LOW:**
  - missing memoization on a proven bottleneck, with the compiler off.

**Overrides:**
- **The React Compiler on:** no memoization finding.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- A fail-open check, client-side data exposure and XSS drop to MEDIUM when exploiting them is harder or reaches less.
- Missing cleanup rises to HIGH when the leak grows with each render.
- An accessibility form: a MEDIUM rises to HIGH when it blocks the task, or when it ships in a shared design-system component.
- An accessibility form: a HIGH drops to MEDIUM when an equally accessible path to the same task exists.
