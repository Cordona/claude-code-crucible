---
name: standard-typescript
description: The single definition of idiomatic, correct TypeScript language discipline, independent of runtime or framework. Composed by any `{tech}-developer`/`{tech}-reviewer` pair that builds TypeScript (e.g. `react-developer`/`react-reviewer` alongside `standard-react`, `cloudflare-workers-developer`/`cloudflare-workers-reviewer` alongside `standard-cloudflare-workers`). Applies whenever TypeScript is written, changed, or reviewed. Defines strict-mode & the `any`/`unknown` boundary, type-narrowing, and Zod schema/validation conventions. This is WHAT good TypeScript looks like at the language level; it does not define runtime- or framework-specific idioms (those live in each platform's own standard), builder workflow (build-core), or reviewer machinery (the matching `{tech}-reviewer`).
---

# Standard: TypeScript (language discipline)

The **one** definition of idiomatic, correct TypeScript at the language level — independent of what runs it. Any tech pair building TypeScript composes this skill alongside its own runtime/framework standard (`standard-react`, `standard-cloudflare-workers`, or a future one) — the same way every pair already composes the cross-cutting standards (`standard-clean-code`, `standard-security`, etc.). A rule changed here moves every TypeScript pair that composes it at once, so keep it narrow: only content that is genuinely true of TypeScript everywhere belongs in this file. The moment a rule needs "...and here's how this looks in a React component" or "...and here's the Workers-generated `Env` type," it belongs in the composing platform standard instead, not here.

This skill defines **WHAT good looks like**. It is **NOT a TypeScript tutorial**: assume fluent TypeScript, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: runtime/framework-specific idioms, builder workflow (`build-core`), or any reviewer's scoring machinery (severity, `category` vocabulary, scope-boundary/handoff — those live with each `{tech}-reviewer`).

Assume **TypeScript 5.x with `strict: true`; Zod 3.x**, unless the project states otherwise. Toolchain specifics that vary by runtime (module target, bundler resolution, `isolatedModules`) are each composing platform standard's own call, not this file's.

## 1. Strict-mode type discipline & the `any`/`unknown` boundary

- **`strict: true`. Never a bare `any`, anywhere.** The fallback for a genuinely unknown shape is `unknown` plus an explicit narrow (a `typeof`/`instanceof` guard, a discriminant check, or a Zod parse) — never a widening cast.
- **`as` assertions and the non-null `!` operator are escape hatches.** Each one must be individually justified by a real constraint, not reached for out of habit.
- **Model domain state with discriminated unions; make illegal states unrepresentable.** Use an **exhaustive `switch` with a `never`-typed default** so a new variant fails to compile until every call site handles it — this is a design tool, not a style preference: let the compiler prove what a test suite would otherwise have to chase.
- **Prefer `satisfies` over a type annotation** where it preserves literal inference; **prefer `as const`** for literal tuples/objects that feed a `z.enum` or a discriminant. Both keep the literal type instead of widening it, without losing the surrounding shape-check.
- **Import types with `import type`** for type-only imports. This is required under `isolatedModules`, but treat it as the default habit regardless of whether a given project's toolchain enforces it — it keeps type-only code from being pulled into a runtime bundle by accident.
- **Narrow nullable values explicitly.** Do not let optional chaining (`?.`) silently mask a value that is genuinely missing when the surrounding logic requires it to be present — a masked `undefined` that should have been a hard failure is a defect, not defensive coding.

## 2. Zod schemas & validation

These are unconditional conventions for this standard, not generic Zod advice restated for its own sake — apply them wherever Zod is used, regardless of which platform standard is composed alongside this one.

- **Schema constants are PascalCase nouns matching the shape** (`UserId`, `CreateUserInput`) — **never suffixed `Schema`** — and the inferred type shares the identical name (`export type X = z.infer<typeof X>`). TypeScript's separate type and value namespaces make this a deliberate convention, not a collision — don't rename either side to "fix" an apparent clash that isn't one.
- **A deliberate three-way strictness split:**
  - schemas modeling data the codebase does **not** control (an external API response, an upstream payload) use **`.passthrough()` explicitly**, with a comment saying why (tolerate fields the source adds later without breaking the parse);
  - schemas modeling data the codebase **does** control (request/input shapes) use plain `z.object()` (default silent strip);
  - `.strict()` is not used.
  **Do not treat `.passthrough()` as laxness or demand `.strict()` reflexively** — the split is intentional and each side has a reason. Changing a schema's strictness is a contract change and needs a stated reason, not a drive-by edit.
- **Validate at the boundary — inbound payloads, outbound responses from a source the codebase doesn't control — then trust the parsed type inward.** No defensive re-checking of an already-parsed value deeper in the call stack; that duplicates the boundary's job and drifts from it over time. **Parsing establishes shape, not sink safety** — a `z.string().url()` parse succeeds on `javascript:alert(1)` just as readily as on `https://...`. Every dangerous sink (a rendered URL, a query, a shell argument) still needs its own sink-specific control per `standard-security` — adding that control is not the "defensive re-checking" this bullet warns against.
- **A Zod parse failure is converted into the composing project's own error model at the boundary — it never escapes as a raw `ZodError` or its default message.** What that error model looks like (an HTTP-status-carrying domain error class, a component-level error state, or something else) is each composing platform standard's call — this file only requires that the conversion happens, not what it converts into.

---
*Standard Version: 1.1 — the shared TypeScript language-discipline rubric, composed alongside a runtime/framework standard by any TypeScript-based tech pair. Lives under `shared/standards/language/` — a third category alongside `shared/standards/lens/` (one standard per `lens-*` reviewer) and `shared/standards/tech/` (one standard per technology, installed with that technology's group): a composed-only, cross-technology base with no dedicated developer/reviewer pair and no `lens-*` reviewer of its own. Every TypeScript tech pair's own reviewer scores against it directly.*
