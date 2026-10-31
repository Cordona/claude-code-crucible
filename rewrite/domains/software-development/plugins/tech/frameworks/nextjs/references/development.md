# Next.js: development

Apply after `SKILL.md`'s rules, beside the language plugin's development rules, before writing any Next.js code.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The Next.js version found** and its router -> the report's `toolchain`, beside the language toolchain, because the reviewer judges the code against the version and router it names.
- **The `verification` items are the language plugin's gate items:** this plugin adds none.

## Defaults when the first message is silent

- **The version and router:** the Next.js version from `SKILL.md`'s Toolchain order, and the App Router.

## Edge cases

- **Pages Router code, a `pages/` directory with no `app/`:** apply no rule from this plugin, and say so in the report's `decisions`.
- **A Server Action or route handler the task touches with no authorization check:** record it in the report's `noticed`, unless the task covers authorization.

## Verification gate

The language plugin's gate covers Next.js code. This plugin adds no step and no tool, and a build (`next build`) is not a per-change gate.

## Self-check before reporting

1. The Next.js version and router were settled in `SKILL.md`'s Toolchain order.
2. Every touched Server Action and route handler authorizes the caller from the server-side session, or the missing check is in `noticed`.
3. Each transaction stays inside one Server Action or route handler invocation.
4. No route-level code splitting is hand-rolled.
5. Every Server Action that changes data revalidates it.
6. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
