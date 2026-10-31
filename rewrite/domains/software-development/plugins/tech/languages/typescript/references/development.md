# TypeScript: development

Apply after `SKILL.md`'s rules, before writing any TypeScript.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The toolchain found** (TypeScript version, `strict` on or off, the package manager and its version, the Node version) -> the report's `toolchain`, because the reviewer judges the code against the versions and strictness it names.
- **Each Verification gate command and its result** -> the report's `verification`, one item per command, its `gate` value as its step names it, because a gate result the report doesn't show reads as a gate that never ran.
- **Each warning, error or finding that predates your change** goes in its command's `note`, with its count.
- **A step you didn't run** is `not_run`, with its reason in `note`, or `narrowed` when `TASK` narrowed it; never leave it out.

## Defaults when the first message is silent

- **The toolchain** comes from `SKILL.md`'s Toolchain order.
- **New code meets `strict` rules,** whatever the project's `tsconfig.json` sets.
- **A new package uses the package manager the repo already uses,** else npm.

## Edge cases

- **`strict` is off:** don't turn it on, since that is a project-wide change; record in the report's `decisions` that new code meets its rules anyway.
- **A workspace or monorepo:** run the gate in the changed package's workspace.
- **A `.js` file in the project:** keep it JavaScript, apply the rules JavaScript can express, and don't convert it to `.ts` unless the task asks.

## Verification gate

Take the baseline before your first edit; run the full gate on every change, before reporting done, through the package manager `SKILL.md`'s Toolchain found (`<pm>` below), the project's own scripts first. Its tools are `node` and that package manager, with `typescript` installed in `node_modules`; ESLint, Prettier or Biome only where the project configures them.

The gate writes only the tools' caches and what the project's scripts write, such as coverage or snapshots.

The gate fetches and installs nothing: with npm, run each tool as `npx --no-install <tool>`, so a missing local binary fails loudly instead of being fetched from the registry. No `node`, no package manager, or a gate tool missing from `node_modules`: record each step that needs it `not_run`, with a note naming what is missing and its install hint: a hint to record, never a command to run.

Before your first edit, run steps 1, 2 and 3 and record each warning, error and finding with its count as the baseline; a new file's baseline is empty. After the change, run every step and compare steps 1, 2 and 3 against the baseline.

1. The format check (gate `format`), only where the project configures a formatter: `<pm> exec prettier --check .` or `<pm> exec biome format .`; for npm, `npx --no-install prettier --check .` or `npx --no-install biome format .`. It passes when your change adds no unformatted file to the baseline. Not configured: `not_run`, with "not configured" as its note.
2. The type check (gate `typecheck`): the project's `typecheck` script; else `<pm> exec tsc --noEmit`; for npm, `npx --no-install tsc --noEmit`. It passes when your change adds nothing to the baseline.
3. The lint check (gate `lint`), only where the project configures ESLint or Biome: the project's `lint` script; else `<pm> exec eslint .` or `<pm> exec biome lint .`; for npm, `npx --no-install eslint .` or `npx --no-install biome lint .`. It passes when your change adds nothing to the baseline. Not configured: `not_run`, with "not configured" as its note.
4. The existing tests (gate `test`): the project's `test` script. None: `not_run`, with "no test command" as its note.

A build (`<pm> run build`) is not a per-change gate.

## Self-check before reporting

1. The toolchain was settled in `SKILL.md`'s order.
2. No bare `any`, and each `as` and `!` is justified.
3. Each `switch` over a union is exhaustive, with a `never`-typed default.
4. Each caught value is narrowed before use.
5. No floating promise.
6. Each gate step ran, or is `not_run` or `narrowed` with its reason.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
