# Accessibility: development

## Reporting

- **No accessibility check configured:** record it with the lint result, naming the stack's tool that would add one (lint rules such as `jsx-a11y`, or axe in its tests such as `jest-axe`).
- **A conflict with the visual design, settled for accessibility:** record it.
- **A colour, size or motion value you can't resolve from the code** (a token defined elsewhere), assumed to meet the bar: record it.

## Self-check before reporting

1. Semantics and names: native elements, ARIA only for a gap, no click handler on a non-interactive element, no skipped heading level, the landmarks, the page's `lang` and title; every control named from visible text where it shows, each visible label inside its name, custom controls with their role and states, every referenced id present and unique.
2. Keyboard, focus and dialogs: all operable by keyboard, focus visible, a logical order, no positive `tabindex` and none on a non-interactive element, Esc closing overlays, focus moved on a route change, no keyboard trap, nothing covering the focused element; each modal dialog with its role, `aria-modal` and name, focus trapped while open and returned on close.
3. Perception: `alt` or hidden for each image, captions, contrast, nothing by colour alone, reduced motion honoured, zoom allowed, reflow at 320 CSS px.
4. Forms, errors and live regions: inputs labelled; errors tied, announced and named in text; required fields marked; `aria-disabled` where a message must stay perceivable; `autocomplete` on personal data; paste allowed in login fields; dynamic changes announced at the right politeness.
5. Pointer: targets at least 24×24 CSS px; each drag with a single-pointer alternative.
6. Conventions: the project's conventions were followed, and none excused a WCAG A/AA miss.
