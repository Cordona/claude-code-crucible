---
name: standard-react
description: The single definition of idiomatic, correct, accessible React + TypeScript — the shared rubric that the react-developer BUILDS to and the react-reviewer REVIEWS against. Applies whenever React/`.tsx` code (including the meta-frameworks Next.js and Remix) is written, changed, or reviewed. Defines TypeScript strictness (`strict: true`, never `any`, justified escape hatches, discriminated-union exhaustiveness), the React state model (right altitude, derived vs duplicated state, server cache), Rules of Hooks and `useId` for stable ids, effects and dependency arrays (dep-identity, cleanup, no async-effect races, stale closures), controlled/uncontrolled inputs, list keys, forms, React Server Component boundaries, hydration correctness and SSR-safety, render performance (memoization where it pays, key/reference stability, no inline-object churn), and accessibility (WCAG 2.2 — semantic elements/roles, keyboard, ARIA, dialog semantics, focus management, contrast, target size, `getByRole`-friendly markup). This is WHAT good React+TS looks like; it does not define builder workflow (build-core), review scoring (the reviewer supplies severity, category vocabulary, the correctness-detective method, and the a11y audit method), or the universal standards (clean-code, testing, security, performance, observability).
---

# Standard: React + TypeScript

The **one** definition of idiomatic, correct, and accessible React + TypeScript. The `react-developer` builds to it; the `react-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we build React and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like**. It deliberately does NOT contain: the builder's workflow (`build-core`) or dev-only tooling gate; the reviewer's scoring machinery — severity, `category` vocabulary, scope-boundary/handoff, the correctness-detective framing, and the accessibility *audit method* (how to verify) all live in the reviewer; or the universal cross-cutting standards (`standard-clean-code`, `standard-testing`, `standard-security`, `standard-performance`, `standard-observability`).

Assume fluent React and TypeScript. This is **not a tutorial** — it encodes the non-default priorities, idioms, and easy-to-miss traps that separate correct, accessible React from code that merely renders.

## Philosophy

- **Correctness before cleverness.** Deterministic render, honest effects, and exhaustive state handling come first; optimization is earned by measurement, not assumed.
- **Accessibility is a build-to property, not a bolt-on.** Semantic, operable, perceivable UI is part of "done" — not a later pass.
- **The type system is a design tool.** Make illegal states unrepresentable; let the compiler prove what tests would otherwise chase.

## 1. TypeScript strictness

- `strict: true`. **Never `any`** — use `unknown` and narrow. `as` assertions and non-null `!` are escape hatches; each one must be justified, not habitual.
- Model domain state with **discriminated unions**; make **illegal states unrepresentable**; use an **exhaustive `switch` with a `never` default** so a new variant fails to compile until handled.
- Type props and boundaries **explicitly**; let inference handle the rest. Props are the typed contract of a component.
- Mutation-sensitive props should be `readonly`; don't accept loosely- or `any`-typed props.
- **Null-safety:** narrow nullable values explicitly; do not let optional chaining (`?.`) silently mask a value that is genuinely missing when it shouldn't be.

## 2. State & derived state

- **State at the right altitude:** local (`useState`/`useReducer`) → lifted to the nearest common parent → **server cache (TanStack Query / SWR)** → **URL** for shareable view state.
- **Never keep server data in `useState`** — use a server-cache library. **Derive state; do not duplicate it** — anything computable from existing state/props should be computed during render, not stored.
- Prefer composition or context over **over-lifting / prop-drilling**; but keep context **values stable** (an unstable provider `value` cascades re-renders across every consumer).
- `useState(prop)` seeds from a prop **once** and does NOT resync when the prop changes — this is a trap unless the "reset on change" is deliberate (see keys, §5). Wrap an **expensive initializer** in `useState(() => …)` so it runs once, not every render.

## 3. Hooks

- **Rules of Hooks:** call hooks only at the top level of a component or another hook — never conditionally, in loops, or outside a component/hook. (Exception: React 19's `use()` **may** be called conditionally — that is by design.)
- **Stable ids with `useId`:** generate ids for `aria-describedby` / `aria-labelledby` / `htmlFor` / `aria-controls` with `useId`, never a hand-rolled or module-level counter. In list-rendered components a hardcoded id **duplicates** across rows and silently breaks the ARIA association — `useId` is the fix.
- **React 19 APIs:** use `use()`, `useActionState`, and `useOptimistic` for their intended purpose; don't misapply them.
- **Refs/DOM:** don't fight React with direct DOM mutation, and don't read a ref's value **during render** (it isn't set yet on first render) — read refs in effects/handlers.

## 4. Effects & dependency arrays

- **Effects synchronize with external systems — they do not derive data.** If a value can be computed during render, compute it there instead of writing it to state from an effect. An unnecessary effect is a defect, not a style choice.
- **Dependency arrays must be complete and honest.** A missing dependency captures a **stale closure** (an outdated `state`/`prop`); reach for the **`setState(prev => …)` updater form** instead of depending on the current value.
- **Dependency identity:** an object/array/function **literal** in a dependency array has a new identity every render, so the effect (or memo) re-fires every render. Stabilize it (`useMemo`/`useCallback`/hoist) or depend on primitives.
- **Always clean up** subscriptions, timers, and listeners in the effect's cleanup function; otherwise they leak and stack up.
- **No `async` effect callback:** `useEffect(async () => …)` returns a promise, which silently breaks cleanup. Declare an inner `async` function and call it, or use an `AbortController`.
- **No async races:** don't set state after unmount, and guard **out-of-order** async responses with cancellation / `AbortController` (or an ignore flag) so a slow earlier request can't overwrite a newer one.

## 5. Inputs, keys & forms

- **Controlled vs uncontrolled:** choose one explicitly. A `value` without an `onChange` freezes the input; flipping between `value` and `defaultValue` is a bug.
- **List keys must be stable and identity-based** — never the array index when the list can reorder, insert, or delete, because index keys bind component state to the wrong row. Conversely, a **deliberately changing `key`** is the idiomatic way to remount and reset a subtree when the underlying entity changes.
- **Forms:** React Hook Form + a **Zod schema as the single source of truth**; share that schema client↔server and **re-validate on the server** — client validation is UX, never a trust boundary.
- **Async UI is not done until its states are:** loading, empty, and error states — plus error boundaries and Suspense where appropriate — are part of "done," not extras.

## 6. Server Components, hydration & SSR-safety

- **Default to Server Components** (Next.js App Router / Remix); add `"use client"` only at the **leaf** that needs interactivity or browser APIs. Keep secrets and data fetching on the **server** — never let server-only code or data cross into a client component or ship into the client bundle.
- **Render deterministically.** During render, avoid `Date.now()` / `Math.random()`, locale/timezone-dependent formatting, and browser-only reads (`typeof window`, `localStorage`) — non-deterministic render produces different server vs client HTML, i.e. a **hydration mismatch**. Gate client-only values behind `useEffect` / `useSyncExternalStore`.
- **SSR-safety:** never touch `window` / `document` / `localStorage` at module scope or during render — it crashes SSR. Note that **effects do NOT run during SSR**, so effect-gated client-only reads are safe.

## 7. Render performance

- **Correctness first; optimize a *proven* re-render problem, not a guess.**
- **If the React Compiler is enabled, do not hand-write `useMemo`/`useCallback` as a habit** — rely on the compiler and reserve manual memoization as a deliberate escape hatch; don't write code that fights the compiler.
- Otherwise: keep **references stable** where they gate memoization, **hoist constant objects/functions** out of render, and keep **context values stable** — new inline object/function/array identities break `memo` and trigger re-render cascades.
- **Virtualize large lists** (>~100 rows) to bound reconciliation and DOM-node cost; keep **keys stable** so rows aren't needlessly remounted.
- **Code-split routes** (`React.lazy` / dynamic import) and lazy-load below-the-fold; watch for accidental **barrel-file imports** bloating the bundle. Wrap async/lazy trees in **Suspense / error boundaries**.

## 8. Accessibility (WCAG 2.2 A/AA)

Accessibility is owned by React code, not a separate concern — semantic, operable, perceivable markup is a build-to property. `getByRole`-friendly markup (correct roles and accessible names) is both the accessible outcome and what makes UI testable. `jsx-a11y` lint rules encode much of the below — treat their violations as errors, not warnings.

- **Semantic HTML first** (`<button>`, `<nav>`, `<main>`, `<a>`); use ARIA only to fill genuine gaps, never to paper over the wrong element. No `<div onClick>` for interactive controls.
- **Keyboard:** everything operable by keyboard; **visible focus** (never `outline:none` without a replacement); logical tab order; **Esc closes overlays**; trap focus in modals and **return focus to the trigger** on close. Never use a **positive `tabindex` (>0)** (it hijacks tab order) or put `tabindex` on non-interactive elements.
- **ARIA & labels:** every control has an accessible name (`<label>`/`aria-label`); associate errors via `aria-describedby`; correct `role`, `aria-expanded`/`aria-controls`; announce async/dynamic changes with `aria-live` at the right politeness (`polite`/`status` vs `assertive`/`alert`). The **visible label must be part of the accessible name** (WCAG 2.5.3).
- **Dialogs** need proper semantics: `role="dialog"` + `aria-modal="true"` + an accessible name, plus focus trap and return.
- **`disabled` vs `aria-disabled`:** a `disabled` control drops out of the accessibility tree and focus order, so its associated error/tooltip is never announced — use `aria-disabled` when the control must remain perceivable.
- **Focus management:** move/return focus across route changes and modal open/close.
- **Structure:** no skipped heading levels; provide `main`/`nav`/`banner` landmarks.
- **Perception:** meaningful `alt` (decorative images hidden); media captions where applicable; **contrast ≥ 4.5:1 text** (≥ 3:1 for large ≥18pt / 14pt-bold) / **≥ 3:1 UI**; never convey information by **color alone**; honor `prefers-reduced-motion`.
- **Target size:** interactive targets ≥ **24×24 CSS px** (WCAG 2.2 SC 2.5.8).
- **Id integrity:** `aria-describedby`/`labelledby`/`controls` must point at a present, **non-duplicated** id — in list-rendered components, generate ids with `useId` (§3).

---
*Standard Version: 1.0 — the shared React + TypeScript rubric. Built to by the react-developer (via build-core); reviewed against by the react-reviewer.*
