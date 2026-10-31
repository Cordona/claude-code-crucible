---
name: language-typescript
description: "TypeScript rules: toolchain, types, unions, async, Zod and lints, plus the developer's verification gate. Use when writing or reviewing TypeScript. A language plugin. Its gate writes only tool caches and what the project's scripts write; needs `node`, a package manager and `typescript`. Not for TypeScript driven only from another file, pure JavaScript, React's or Next.js's own rules (framework plugins), or rules every language shares (`code-developer`, standard plugins)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: TypeScript
---

# Language: TypeScript

The rules that are specific to TypeScript. Every role receives this file in its first message. A developer then receives `references/development.md` right after it: what to report, the defaults, the edge cases and the verification gate. A reviewer receives `references/review.md` right after it instead: how to judge a finding and how to grade it.

## Scope

- **In:** TypeScript on Node or in the browser, in a project with a `package.json` and a `tsconfig.json`: backends, libraries, CLIs, and the code of a React or Next.js app that no framework rule covers.
- **In:** `.js` files inside such a project.
- **In:** code on a web framework with no plugin of its own, such as Express.
- **Out:** TypeScript driven only from another file, such as a Dockerfile `RUN npm run build` line or a CI step.
- **Out:** a pure-JavaScript project, with no `tsconfig.json`: this file holds no rules for it.
- **Out:** React and Next.js rules: their framework plugins hold them.
- **Out:** Deno and Bun runtime specifics. Bun used only as the package manager is covered by Toolchain.

## Toolchain

Settle it before writing a line. Take each fact from the first source below that sets it:

1. The package manager: `package.json`'s `packageManager` field; else the lockfile: `pnpm-lock.yaml` for pnpm, `yarn.lock` for Yarn, `package-lock.json` for npm, `bun.lock` or `bun.lockb` for Bun.
2. The TypeScript version: `typescript` in `package.json`'s `devDependencies`, else in the lockfile.
3. Strictness: `tsconfig.json`'s `strict`, following its `extends` chain.
4. The Node version: `package.json`'s `engines.node`, else `.nvmrc`, `.node-version` or `.tool-versions`.
5. The commands: the project's own `typecheck`, `lint` and `test` scripts in `package.json`, over raw commands.
6. What the project's own docs on its TypeScript code say, where the task's context lists them.
7. Otherwise TypeScript 5.x with `strict: true`, on the default Node version (see Version ledger).

## Type discipline

- **Write to `strict: true`:** every rule below assumes its checks.
- **Never a bare `any`:** it turns off type checking for every value it reaches.
- **An unknown shape is `unknown` plus an explicit narrow** (`typeof`, `instanceof`, a discriminant check or a Zod parse), never a widening cast.
- **Each `as` and each non-null `!` is justified by a real constraint:** both are escape hatches the compiler no longer checks.
- **Narrow a nullable value explicitly:** a `?.` that masks a value the logic needs turns a hard failure into a silent `undefined`.
- **A `catch` variable is `unknown`:** narrow it before using it as an `Error`, as in `err instanceof Error ? err.message : String(err)`.

## Discriminated unions

- **Model domain state with discriminated unions,** so an illegal state can't be written.
- **Switch over a union exhaustively, with a `never`-typed default:** a new variant then fails to compile until each call site handles it.

## Async and promises

- **No floating promise:** await it, return it, or `void` it with a written reason, since an unhandled rejection can end a Node process.
- **`Promise.all` by default; `Promise.allSettled` when each outcome must be handled even after one rejects:** `all` rejects on the first failure while the other promises keep running.
- **`AbortController` for work that must be cancellable,** or whose slow earlier result must not overwrite a newer one.

## Zod

Apply where the project uses Zod.

- **Schema constants are PascalCase nouns with no `Schema` suffix** (`UserId`, `CreateUserInput`), and the `z.infer` type shares the name: TypeScript keeps types and values in separate namespaces, so the two don't collide.
- **Data the codebase doesn't control uses `.passthrough()`, with a comment saying why:** the parse then tolerates fields the source adds later.
- **Data the codebase controls uses plain `z.object()`,** which strips unknown keys.
- **No `.strict()`:** the two rules above cover both kinds of data.
- **A strictness change is a contract change,** made only with a stated reason.
- **Validate at the boundary, then trust the parsed type inward:** a re-check deeper in the call stack duplicates the boundary's job and drifts from it.
- **A parse sets shape, not sink safety:** `z.string().url()` accepts `javascript:alert(1)`, so each dangerous sink still needs its own control.
- **Convert a `ZodError` into the project's error model at the boundary:** never let the raw error or its default message escape.

## Type-level idioms

- **`satisfies` over a type annotation where it keeps literal inference:** the value keeps its literal type and is still shape-checked.
- **`as const` for literal tuples and objects that feed a `z.enum` or a discriminant,** so the literal type is not widened to `string`.
- **`import type` for type-only imports,** so type-only code stays out of the runtime bundle.

## Language micro-performance

- **No `.map().filter().reduce()` chain of full-array passes on a hot path:** each link allocates a new array, so use one pass there and the readable chain elsewhere.
- **No re-validation of a value TypeScript has already narrowed:** the narrow already proved it, so the check is repeated work.

## Naming

- **Types and classes are PascalCase, and an interface carries no `I` prefix:** it is a type like any other.
- **`UPPER_SNAKE_CASE` only for a genuine compile-time or config constant** (`MAX_RETRIES`); every other variable, and every function, is camelCase.

## TypeScript mechanisms for the shared standards

- **Supply chain:** the package manager's own audit (`npm audit`, `pnpm audit`, `yarn npm audit`), and pinned dependencies.
- **Docs:** TSDoc on a public item only when its signature can't state a constraint, a failure condition or behaviour beyond it.

## Lints

- **Type-check with no new error:** treat each one your change adds as a gate failure. Old ones in an existing project would otherwise fail every change.
- **Honor ESLint, Prettier or Biome where the project configures them,** with no new finding.
- **Name each finding by its rule id** (`@typescript-eslint/no-floating-promises`, `TS2322`): a finding with no id can't be matched against the baseline the gate compares to.
- **Every `eslint-disable`, `biome-ignore` and `@ts-expect-error` carries its written reason:** a reasoned one on a line complies, an unexplained one is a defect, and a rule turned off or down in the project's lint config is a defect too.
- **`@ts-expect-error` over `@ts-ignore`:** it fails once the error it hides is gone, so it can't go stale.

## Version ledger

| Fact | Value | Last verified |
|---|---|---|
| Default TypeScript version (Toolchain step 7) | 5.x | not verified by a command: the legacy default, kept on 2026-10-31 |
| Latest stable TypeScript | 7.0.2 | 2026-10-31, `npm view typescript version`, macOS 27.2 |
| Default Node version (Toolchain step 7) | 26, the LTS line "Lithium" (v26.13.0) | 2026-10-31, `curl -s https://nodejs.org/dist/index.json` (first lts entry), macOS 27.2 |
| Default Zod version | 3.x | not verified by a command: the legacy default, kept on 2026-10-31 |
