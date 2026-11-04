# React: review

## Correctness

- **Check for these React correctness defects:**
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

## Severity

- **CRITICAL:** none of its own.
- **HIGH:**
  - server data kept in `useState`;
  - an unsanitized `dangerouslySetInnerHTML`, or a supplied `href` or `src` with an unchecked scheme;
  - a secret or token read into client-bundled code, `localStorage` or `sessionStorage`;
  - a label or `aria-*` reference that doesn't resolve to one element (`for` in place of `htmlFor`, an id not from `useId` that repeats and that a label or an `aria-*` reference points at);
  - a raw `ZodError` shown instead of an error tied to its field.
- **MEDIUM:**
  - missing effect cleanup;
  - an id not from `useId` that repeats and that no label or `aria-*` reference points at.
- **LOW:**
  - missing memoization on a proven bottleneck, with the compiler off.

**What moves a level:**
- Missing cleanup rises to HIGH when the leak grows with each render.
- An accessibility form: a MEDIUM rises to HIGH when it blocks the task, or when it ships in a shared design-system component.
- An accessibility form: a HIGH drops to MEDIUM when an equally accessible path to the same task exists.
