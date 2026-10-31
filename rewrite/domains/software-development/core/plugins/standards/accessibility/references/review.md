# Accessibility: review

Apply after `SKILL.md`'s rules when judging code by the accessibility rules: judge the change by every rule there, then apply these. This file holds how to judge a finding and how to grade it; it sets no category vocabulary and no finding-ID prefix.

- **Walk the rendered surfaces in this order:** semantics, keyboard, names and labels, focus, dialogs, `disabled`, media, colour and motion, structure, target size, ids.
- **No rendered UI, no finding:** a change that renders nothing different gets none; say so, and never manufacture one.
- **No finding without the blocked user and the task they can't do:** a keyboard user can't reach the menu; a screen reader announces nothing when the form fails.
- **A component library's accessible primitive used as documented is the control, so no finding;** a misuse of it is one.
- **Judge contrast and size only where the values resolve from the code;** a value defined elsewhere is no finding.
- **A change that disables or downgrades a configured accessibility lint rule is a finding.**
- **A lint suppression with no written reason is a finding.**
- **Correctness goes to the tech lens:** hand it over in `not_reviewed`, ungraded.

## Severity

Where an accessibility defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - none for this lens.
- **HIGH:** a WCAG A/AA miss that blocks a user from a task:
  - a control a keyboard can't operate, or one with no accessible name;
  - a keyboard trap;
  - an unlabelled input;
  - an error not tied to its field, or not announced;
  - focus lost when a dialog opens or closes, or on a route change;
  - an informative image with no `alt`;
  - information carried by colour alone;
  - text below the contrast bar on content the task needs.
- **MEDIUM:** a miss that hinders but doesn't block:
  - the wrong live-region politeness;
  - a skipped heading level or a missing landmark;
  - a target below 24×24 CSS px;
  - motion with no reduced-motion path;
  - a visible label missing from the accessible name;
  - a positive `tabindex`;
  - a duplicated id;
  - a disabled or downgraded accessibility lint rule.
- **LOW:**
  - a decorative image not hidden;
  - redundant ARIA on a native element;
  - a lint suppression with no written reason.

**Overrides:**
- Never lower a real miss because the project does it the same way everywhere.

**What moves a level:**
- A MEDIUM rises to HIGH when it blocks the task, or when it ships in a shared design-system component.
- A HIGH drops to MEDIUM when an equally accessible path to the same task exists.
