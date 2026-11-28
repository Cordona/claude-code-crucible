---
name: standard-accessibility-build
description: "Accessibility rules for a build job agent, preloaded through its agent file. Not for main."
user-invocable: false
metadata:
  label: Accessibility, build
---

# Accessibility: build

## Reporting

- **No accessibility check configured:** record it with the lint result, naming the stack's tool that would add one (lint rules such as `jsx-a11y`, or axe in its tests such as `jest-axe`).
- **A conflict with the visual design, settled for accessibility:** record it.
- **A colour, size or motion value you can't resolve from the code** (a token defined elsewhere), assumed to meet the bar: record it.
