# Next.js: build

## Edge cases

- **Pages Router code, a `pages/` directory with no `app/`:** apply no rule from this plugin, and record that none applied.
- **A Server Action or route handler the task touches with no authorization check:** record it, unless the task covers authorization.

## Verification gate

This plugin adds no gate step and no tool, and a build (`next build`) is not a per-change gate.
