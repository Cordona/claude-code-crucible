---
name: standard-accessibility
description: WCAG 2.2 A/AA accessibility rubric in HTML and ARIA terms — semantics, names, keyboard and focus, perception, forms, errors, live regions, pointer. Use when writing or reviewing code that renders an HTML UI a person uses, in any stack. Injected into the agent's first message when loaded. Writes nothing. Not for backends, libraries without UI, config or docs, native mobile, terminal or canvas-only UIs, HTML email, test code (standard-testing), or a framework's own form (its framework plugin).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Accessibility
---

# Standard: Accessibility

What accessible code holds, in any UI stack: every person can perceive and operate what it renders, by keyboard, screen reader or pointer. Build it in as the markup is written: never leave it to an audit. Every role receives this file in its first message. A developer receives `references/development.md` right after it, when developing: what to report and the self-check. A reviewer receives `references/review.md` right after it instead, when reviewing: how to judge a finding and how to grade it.

It is grounded in WCAG 2.2, WAI-ARIA and the ARIA Authoring Practices Guide. A tool this plugin names (axe, `jest-axe`) is an example only: map it to the stack in front of you.

## Scope

- **In:** code the developer writes or changes that renders a UI a person uses, in any stack that renders HTML, server templates included: markup, components, templates, the styles that affect perception or focus (contrast, focus outline, motion), and client script that moves focus or changes content.
- **Out:** backends, libraries without UI, config, docs, and a change that renders nothing different (a pure state hook, a data fetcher).
- **Out until a plugin of their own covers them:** native mobile, terminal and canvas-only UIs, and HTML email.
- **Test code is out:** a test that queries by role is `standard-testing`'s.
- **Project conventions:** follow the project's component library, focus helpers and accessibility lint config. A convention never excuses a WCAG A/AA miss: it is a defect even where the project does the same.

## Any UI stack

- **Build to WCAG 2.2 levels A and AA; AAA is out:** AA is the level a conformance claim targets.
- **Map each rule to the stack in front of you** (JSX, a Vue or Svelte template, a server template): the rules are stated in HTML and ARIA terms.
- **Judge what renders, not the source syntax:** a keyboard and a screen reader meet the output, never the template.
- **Prefer a native element to an ARIA role** (ARIA's first rule): the native element brings its keyboard behaviour and states with it.

## 1. Semantics and structure

- **Use the semantic element for the job** (`<button>`, `<a>`, `<nav>`, `<main>`): it carries its role and keyboard behaviour.
- **Use ARIA only to fill a genuine gap, never to paper over the wrong element:** ARIA changes what is announced, not how the element behaves.
- **Never put a click handler on a non-interactive element** such as a `<div>` or `<span>`: a keyboard can't reach it and a screen reader announces no control.
- **Never skip a heading level:** screen-reader users move through a page by its headings.
- **Provide the `main`, `nav` and `banner` landmarks:** they let a user jump past repeated content.
- **Set the page's `lang`** (3.1.1): a screen reader picks its pronunciation from it.
- **Give each page a descriptive title** (2.4.2): it is the first thing announced.

## 2. Names, roles and states

- **Give every control an accessible name, from visible text by default** (a `<label>` or the control's own content; `aria-labelledby` for visible text elsewhere; `aria-label` only when no text shows): a control without one is announced by its role alone.
- **Make the visible label part of the accessible name** (2.5.3): a voice-control user says the words they see.
- **Give a custom control the right `role` and states** (`aria-expanded`, `aria-controls`): its state is how a screen-reader user learns what changed.
- **Point every `aria-describedby`, `aria-labelledby` and `aria-controls` at an id that is present and unique on the page:** a missing or duplicated id breaks the association silently.

## 3. Keyboard and focus

- **Make everything operable by keyboard:** many users have no pointer.
- **Keep focus visible; never `outline: none` without a replacement style:** a keyboard user loses their place.
- **Keep the tab order logical,** following the reading order.
- **Never use a positive `tabindex`:** it hijacks the tab order.
- **Never put `tabindex` on a non-interactive element:** it adds a stop that does nothing.
- **Close an overlay on Esc:** it is the keyboard user's way out.
- **Move focus to the new content on a route change:** otherwise focus stays on a control that is gone, and the change goes unannounced.
- **Never trap the keyboard** (2.1.2): focus can always leave a component by keyboard; a modal's trap (section 4) ends when it closes.
- **Never let sticky content cover the focused element** (2.4.11): the user can't see where they are.

## 4. Dialogs

- **Give a modal dialog `role="dialog"`, `aria-modal="true"` and an accessible name:** a screen reader then announces it and ignores the page behind it.
- **Trap focus inside an open modal dialog:** focus that slips behind it lands on content the user can't see.
- **Return focus on close to the control that opened the dialog:** otherwise the user restarts from the top of the page.

## 5. Perception

- **Give every informative image a meaningful `alt`:** without it a screen reader reads the file name or nothing.
- **Hide a decorative image from assistive technology** (`alt=""`): it is noise to a screen-reader user.
- **Caption media:** deaf users get spoken content only from captions.
- **Give text a contrast of at least 4.5:1, and large text (18pt, or 14pt bold) at least 3:1:** low-vision users can't read fainter text.
- **Give UI components a contrast of at least 3:1:** a faint border or icon hides the control.
- **Never carry information by colour alone:** colour-blind users miss it.
- **Honor `prefers-reduced-motion`:** motion can trigger nausea or seizures.
- **Never disable zoom** (1.4.4): low-vision users enlarge the page to read it.
- **Let content reflow at 320 CSS px wide without scrolling in two directions** (1.4.10): a zoomed page must still read in one column.

## 6. Forms and errors

- **Label every input:** an unlabelled input is announced with no purpose.
- **Tie each error to its field with `aria-describedby`:** a screen-reader user hears it when the field gets focus.
- **Announce an error when it appears** (section 7): an unannounced error looks to a screen-reader user like a form that did nothing.
- **Name the error in text** (3.3.1): an icon or a red border alone says nothing to many users.
- **Mark required fields** (3.3.2): the user learns it before submitting, not from an error.
- **Use `aria-disabled`, not `disabled`, when the control's error or tooltip must stay perceivable:** a `disabled` control drops out of the accessibility tree and the focus order.
- **Set `autocomplete` on personal-data fields** (1.3.5): the browser fills them, and assistive technology can recognise them.
- **Allow paste in login fields** (3.3.8): a password manager depends on it.

## 7. Live regions

- **Announce an async or dynamic change with `aria-live`:** a change the focus doesn't reach is otherwise silent.
- **Default to `polite` (or `role="status"`); use `assertive` (or `role="alert"`) only for what must interrupt the user:** an assertive region cuts off whatever is being read.

## 8. Pointer

- **Make every interactive target at least 24×24 CSS px** (2.5.8): a small target is hard to hit with a tremor or a thumb.
- **Give every drag a single-pointer alternative** (2.5.7): not every user can hold and move a pointer.
