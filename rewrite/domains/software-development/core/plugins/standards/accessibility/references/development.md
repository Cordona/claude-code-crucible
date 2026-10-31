# Accessibility: development

Apply after `SKILL.md`'s rules, before writing code.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The accessibility check the project configures and its result** (lint rules such as `jsx-a11y`, or axe in its tests such as `jest-axe`) -> the report's `verification`, taken from the language plugin's lint and test steps, never a second run, because the reviewer reads the tool's verdict there.
- **No accessibility check configured** -> the report's `verification` (`gate` `lint`, `result` `not_run`, "no a11y check configured", with the stack's tool named in `note`), and nothing added to the project, because a missing check is a gap only the report shows.
- **A conflict with the visual design, settled for accessibility** -> the report's `decisions`, because the design's owner sees the change only there.
- **A colour, size or motion value you can't resolve from the code** (a token defined elsewhere), assumed to meet the bar -> the report's `open` (`assumption`), because the reviewer judges contrast and size only from values the code resolves.

## Self-check before reporting

1. Semantics and names: native elements, ARIA only for a gap, no click handler on a non-interactive element, no skipped heading level, the landmarks, the page's `lang` and title; every control named from visible text where it shows, each visible label inside its name, custom controls with their role and states, every referenced id present and unique.
2. Keyboard, focus and dialogs: all operable by keyboard, focus visible, a logical order, no positive `tabindex` and none on a non-interactive element, Esc closing overlays, focus moved on a route change, no keyboard trap, nothing covering the focused element; each modal dialog with its role, `aria-modal` and name, focus trapped while open and returned on close.
3. Perception: `alt` or hidden for each image, captions, contrast, nothing by colour alone, reduced motion honoured, zoom allowed, reflow at 320 CSS px.
4. Forms, errors and live regions: inputs labelled; errors tied, announced and named in text; required fields marked; `aria-disabled` where a message must stay perceivable; `autocomplete` on personal data; paste allowed in login fields; dynamic changes announced at the right politeness.
5. Pointer: targets at least 24×24 CSS px; each drag with a single-pointer alternative.
6. Conventions: the project's conventions were followed, and none excused a WCAG A/AA miss.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
