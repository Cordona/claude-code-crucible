# TypeScript: development

## Defaults when nothing given says otherwise

- **A new package uses the package manager the repo already uses,** else npm. A new dependency goes into `package.json` only; its install is left to the human: record it, and a gate step that needs it doesn't run.

## Edge cases

- **`strict` is off:** don't turn it on, since that is a project-wide change; record that new code meets its rules anyway.
- **A workspace or monorepo:** run the gate on the changed package through the package manager's workspace option.
- **A `.js` file in the project:** keep it JavaScript, apply the rules JavaScript can express, and don't convert it to `.ts` unless the task asks.

## Verification gate

The gate runs through the package manager the Toolchain found (`<pm>` below), the project's own scripts first. Its tools are `node` and that package manager, with `typescript` installed in `node_modules`; ESLint, Prettier or Biome only where the project configures them.

With npm, run each tool as `npx --no-install <tool>`, so a missing local binary fails loudly instead of being fetched from the registry. No `node`, no package manager, or a gate tool missing from `node_modules`: each step that needs it doesn't run, with what is missing and its install hint as the reason.

Steps 1, 2 and 3 carry a baseline of each warning, error and finding with its count; a new file's baseline is empty. After the change, run every step and compare steps 1, 2 and 3 against the baseline.

1. The format check (gate `format`), only where the project configures a formatter: `<pm> exec prettier --check .` or `<pm> exec biome format .`; for npm, `npx --no-install prettier --check .` or `npx --no-install biome format .`. Not configured: it doesn't run, for the reason "not configured".
2. The type check (gate `typecheck`): the project's `typecheck` script; else `<pm> exec tsc --noEmit`; for npm, `npx --no-install tsc --noEmit`.
3. The lint check (gate `lint`), only where the project configures ESLint or Biome: the project's `lint` script; else `<pm> exec eslint .` or `<pm> exec biome lint .`; for npm, `npx --no-install eslint .` or `npx --no-install biome lint .`. Not configured: it doesn't run, for the reason "not configured".
4. The existing tests (gate `test`): the project's `test` script in its non-updating CI form (`CI=true <pm> test`), so no snapshot is written. None: it doesn't run, for the reason "no test command".

A build (`<pm> run build`) is not a per-change gate.

## Self-check before reporting

1. The toolchain was settled in the Toolchain order.
2. No bare `any`, and each `as` and `!` is justified.
3. Each `switch` over a union is exhaustive, with a `never`-typed default.
4. Each caught value is narrowed before use.
5. No floating promise.
