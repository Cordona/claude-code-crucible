# Next.js: development

## Edge cases

- **Pages Router code, a `pages/` directory with no `app/`:** apply no rule from this plugin, and record that none applied.
- **A Server Action or route handler the task touches with no authorization check:** record it, unless the task covers authorization.

## Verification gate

This plugin adds no gate step and no tool, and a build (`next build`) is not a per-change gate.

## Self-check before reporting

1. The Next.js version and router were settled in the Toolchain order.
2. Every touched Server Action and route handler authorizes the caller from the server-side session, or the missing check is recorded.
3. Each transaction stays inside one Server Action or route handler invocation.
4. No route-level code splitting is hand-rolled.
5. Every Server Action that changes data revalidates it.
