# React: development

Apply after `SKILL.md`'s rules, beside the language plugin's development rules, before writing any React code.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The React version found** and the React Compiler's state -> the report's `toolchain`, beside the language toolchain, because the reviewer judges the code against the React version and compiler state it names.
- **The `verification` items are the language plugin's gate items:** this plugin adds none.

## Defaults when the first message is silent

- **The React version** comes from `SKILL.md`'s Toolchain order.
- **The React Compiler** is off unless `SKILL.md`'s Toolchain test finds it on.

## Edge cases

- **The React Compiler is on:** write no code that fights it, and take the on branch of `SKILL.md`'s Render performance rules.
- **`eslint-plugin-react-hooks` is not configured:** make no project-wide change (the lint config) unless the task covers it; record the change the code needs in the report's `noticed`.

## Verification gate

The language plugin's gate covers React code: its type check, its lint with the `react-hooks` rules where the project configures them, and the existing tests. This plugin adds no step and no tool.

## Self-check before reporting

1. The React version and the compiler's state were settled in `SKILL.md`'s Toolchain order.
2. Hooks are called only at the top level, and each effect lists every dependency, cleans up, and takes no `async` callback.
3. No server data sits in `useState`, and no derived state is stored.
4. List keys are stable identities.
5. Render is deterministic, with no browser read in it.
6. Each `dangerouslySetInnerHTML` is sanitized, each supplied URL scheme is checked, and labels are paired by `htmlFor` with ids from `useId`.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
