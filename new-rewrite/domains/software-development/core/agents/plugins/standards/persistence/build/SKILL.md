---
name: standard-persistence-build
description: "Persistence rules for a build job agent, preloaded through its agent file. Not for main."
user-invocable: false
metadata:
  label: Persistence, build
---

# Persistence: build

## Reporting

- **The store's guarantees, with each choice they drove** (a saga over a transaction, offset paging kept, a forward-fix in place of a down step): record it.
