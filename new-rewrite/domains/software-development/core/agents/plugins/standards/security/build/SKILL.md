---
name: standard-security-build
description: "Security rules for a build job agent, preloaded through its agent file. Not for main."
user-invocable: false
metadata:
  label: Security, build
---

# Security: build

A new dependency's lock entry comes with its install: the lock rule (A03) holds for the dependencies already installed.

## Reporting

- **No SCA scanner in the repo's CI** (A03): record that the scan didn't run, with the stack's scanner to add.
- **A secret that needs revocation and rotation** (A02): record it, with where it is: its location when **found in source**, the commit holding it when **found only in git history**, or the last commit holding it when **your change removes it from source**.
