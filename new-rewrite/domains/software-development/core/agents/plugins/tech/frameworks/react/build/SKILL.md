---
name: framework-react-build
description: "React rules for a build job agent, preloaded through its agent file. Not for main."
user-invocable: false
metadata:
  label: React, build
---

# React: build

## Edge cases

- **The React Compiler is on:** write no code that fights it, and take the on branch of the Render performance rules.
- **`eslint-plugin-react-hooks` is not configured:** make no project-wide change (the lint config) unless the task covers it; record the change the code needs, with the file it goes in where that file exists.
- **The project has no server-cache library:** add none unless the task covers it; record the change the code needs.

## Verification gate

This plugin adds no gate step and no tool.
