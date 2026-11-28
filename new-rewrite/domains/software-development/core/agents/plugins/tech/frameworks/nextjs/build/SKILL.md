---
name: framework-nextjs-build
description: "Next.js rules for a build job agent, preloaded through its agent file. Not for main."
user-invocable: false
metadata:
  label: Next.js, build
---

# Next.js: build

## Edge cases

- **Pages Router code, a `pages/` directory with no `app/`:** apply no rule from this plugin, and record that none applied.
- **A Server Action or route handler the task touches with no authorization check:** record it, unless the task covers authorization.

## Verification gate

This plugin adds no gate step and no tool, and a build (`next build`) is not a per-change gate.
