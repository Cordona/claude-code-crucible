# React: development

## Edge cases

- **The React Compiler is on:** write no code that fights it, and take the on branch of the Render performance rules.
- **`eslint-plugin-react-hooks` is not configured:** make no project-wide change (the lint config) unless the task covers it; record the change the code needs, with the file it goes in where that file exists.

## Verification gate

This plugin adds no gate step and no tool.

## Self-check before reporting

1. The React version and the compiler's state were settled in the Toolchain order.
2. Hooks are called only at the top level, and each effect lists every dependency, cleans up, and takes no `async` callback.
3. No server data sits in `useState`, and no derived state is stored.
4. List keys are stable identities.
5. Render is deterministic, with no browser read in it.
6. Each `dangerouslySetInnerHTML` is sanitized, each supplied URL scheme is checked, and labels are paired by `htmlFor` with ids from `useId`.
