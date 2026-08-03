# Spec: Crucible Management Hub — Domain-Model Screens (Addendum)

**Status:** draft, round 7 — one behavioral clarification arising from implementation review. Round 6 was a presentation pass (display naming, list formatting, List and Doctor's structure); this round records a single deliberate retirement of a base-spec screen, so the implementation no longer diverges silently from a screen that spec still describes.

**What changed, round 7:**
- **The blocking-dependents 3-way decision screen is RETIRED, in favor of automatic Kept/Cascade resolution.** The base spec describes a numbered decision screen for the case where a selected-for-removal unit is still required by something that stays installed — `1) Cascade / 2) Skip / 3) Cancel`, with the agent-facing `HUB_BLOCKED_REASON=dependents_present`. That screen is deliberately not implemented, and this entry is the record of that decision rather than an implementation gap:
  - The domain model has **exactly one** cross-domain shared unit (the GitHub-auth procedure under `accounts/`, required by Software Development's baseline and by Project Management's GitHub backend), and its retention question has only one sensible answer in either direction. When a consumer remains, the unit is **Kept** — refusing the whole action, or offering to cascade a still-needed prerequisite out from under an installed domain, would both be worse outcomes than simply holding it back and saying so. When no consumer remains, it **Cascades** out, because an unreachable leftover no component selection can name would otherwise be permanently unremovable.
  - Nothing is hidden by the automation: both outcomes are itemized on the dry-run preview *before* the confirm prompt — a `Kept (still required by something that stays installed):` block naming each remaining consumer, and an `Also removing (nothing that stays installed requires these any more):` block. The user still consents, on a screen that states the resolution; they are simply not asked to arbitrate a choice with one defensible answer.
  - `dependents_present` therefore remains in the base spec's published `HUB_BLOCKED_REASON` set but is **never emitted**. `HUB_KEPT_COUNT` (plus the preview's Kept block) is how an agent observes the retention outcome.
  - **If a second cross-domain dependency is ever introduced**, revisit this: with more than one shared unit, or a shared unit with genuinely competing consumers, a real 3-way choice could exist and the retired screen would become the right answer again.

**What changed, round 6:**
- **Display naming: kebab-case becomes Sentence case everywhere a name is shown to a human.** `python` → `Python`, `shell-script` → `Shell script`, `python-developer` → `Python agent developer`. Internal flag/skill names (`--technologies=python`, `standard-python`) are unaffected — this is a display rule, not a rename of anything on disk. Two mechanical exceptions, flagged rather than silently decided: `PHP` and `DevOps`/`GTD` keep their real-world capitalization (`Php`/`Devops`/`Gtd` would misrepresent an acronym/brand) — happy to switch to strict mechanical conversion if preferred.
- **§6's confirm screen: technologies collapse to one line each.** `+ python-developer / + python-reviewer` on two lines becomes `+ Python` on one, with a single parenthetical stated once — `(installs a tech pair — developer and reviewer)` — rather than repeated per technology. The full pair still counts as 2 real files in the arithmetic; only the display line collapses.
- **Every baseline/dependency block is now a real list — one item per line, consistently.** Round 5 bundled several items onto one line (`+ flow-implementation + flow-review + review-boundaries`); that's gone. Every block in §6 is one name per line, elided the same way as before (`... and N more`) when long.
- **Domain headers drop screaming caps and any parenthetical count** (`SOFTWARE DEVELOPMENT (17 selectable)` → `Software Development`) — the count was noise, not information a user acts on here.
- **List is restructured around status, not domain — a real reversal of the original domain-grouping request, made explicitly because a clearer instruction arrived.** Three groups, always: **Installed** (`✓`, green), **Available** (`+`, blue — reusing the base spec's existing "addition" color rather than inventing a new one), **Diverged** (`!`, yellow). No domain headers, no selectable/baseline distinction shown — an installed item is just installed, regardless of which domain or install mechanism put it there. Every real component appears somewhere in one of these three groups.
- **Doctor drops component listing entirely.** It is now exactly two sections — **Required tools** and **Accounts** — plus a summary/next-steps scoped to only those two things. Anything about what's installed/diverged is List's job now, not Doctor's.
- Everything else (§0/§2/§4/§5's mechanism, the CLAUDE.md/contracts treatment, the PM backend split) is unchanged from round 5.

**Created:** 2026-07-31 (round 1); corrected 2026-07-31 (rounds 2-6); clarified 2026-08-01 (round 7)
**Repos in scope:** claude-code-crucible (terminal UI only — no implementation detail; addendum to the base spec below)

**Relationship to the existing spec:** unchanged — an addendum to `.crucible/docs/specs/2026/07/30/crucible-management-hub-ui.draft.md` (round 9, "the base spec").

---

## Counted inventory (unchanged from round 5 in substance, renamed for display below)

- **Software Development baseline — 44 units.** Software Development — technology fan-out — 1 `standard-{tech}` per selected technology.
- **Project Management — 7 units, split:** baseline 3 (`Project manager`, `Standard backlog artifacts`, `Flow project management`); `GitHub backend` (1, real skill: `procedure-gh-issues`); `Jira backend` (3, real skills: `procedure-jira`, `procedure-jira-auth`, `standard-jira-artifacts`, always installed/removed together).
- **GTD — 3 units:** `Flow inbox`, `GTD inbox writer`, `Procedure inbox capture`.

---

## 0-1. Research note & vocabulary

*(Unchanged in mechanism from round 5 — domain replaces tier, lenses and the build/review facades are baseline, one remaining per-technology trigger. See round 5's text for the full statement; this round only changes display naming and the two listing screens below.)*

**Display-naming rule (round 6):** any kebab-case internal name shown to a human converts to Sentence case (hyphens → spaces, capitalize the first letter only). A dev/reviewer pair displays as `{Technology} agent developer` / `{Technology} agent reviewer`; a lens reviewer displays as `{Name} review lens`. `PHP`, `DevOps`, and `GTD` are kept in their conventional capitalization rather than mechanically converted (`Php`, `Devops`, `Gtd`) — flagged as a deliberate exception, reversible on request.

---

## 2. Onboarding — domain multi-select

```
Welcome to the Crucible Management Hub          (b: back · q: quit · ?: help)
Which domain(s) do you want to install?                                [dim]
(space: toggle · a: select all · enter: confirm)                       [dim]

  [x] Software Development         technologies, review swarm, git ops
  [ ] Project Management           GitHub/Jira ticket authoring
  [ ] Getting Things Done (GTD)    capture, triage, process an inbox

  1 selected
```

---

## 3. Software Development — select technologies

```
Software Development — select technologies      (b: back · q: quit · ?: help)
(space: toggle · a: select all · type to filter · enter: confirm)      [dim]

  [x] Python
  [x] React
  [ ] Kotlin
  [ ] Rust
  [ ] Java
  [ ] PHP
  [ ] Shell script
  [ ] DevOps
  [ ] Tests developer

  2 selected
```

**Empty-selection rule:** blocked inline — `Software Development doesn't do anything without at least one technology. Choose at least one, or press "b" to remove Software Development from your selection.`

**Agent-facing equivalent:** the non-interactive path exits `HUB_STATUS=blocked` with **`HUB_BLOCKED_REASON=selection_required`**. That value is a member of the base spec's published closed set (see `crucible-management-hub-ui.draft.md`, "Agent-facing mode"), and **`selection_required` is the one normative spelling** — identical in that spec, here, and in the code. Although this section describes the screen as a domain's *sub-selection*, the value is **not** spelled `subselection_required`.

**Unsatisfiable domain (no candidates at all):** if the framework source contains **no** technologies whatsoever, this screen must not be shown — an empty checklist can only be confirmed empty, which re-triggers the empty-selection rule and returns the same empty screen forever. The domain is reported as not installable and dropped from the selection instead.

---

## 4. Project Management — select backend(s)

```
Project Management — select backend(s)          (b: back · q: quit · ?: help)
(space: toggle · a: select all · enter: confirm)                       [dim]

  [x] GitHub   issues
  [ ] Jira     tickets, workflow

  1 selected
```

**Empty-selection rule:** blocked inline — `Project Management can't create or update tracked work without at least one backend. Choose GitHub, Jira, or both, or press "b" to remove Project Management from your selection.`

**Agent-facing equivalent:** as in §3 — `HUB_STATUS=blocked` / **`HUB_BLOCKED_REASON=selection_required`**, the same single normative spelling.

**Unsatisfiable domain:** as in §3 — a source with no backend skills at all drops Project Management rather than showing an inescapable empty checklist.

---

## 5. Getting Things Done (GTD) — no sub-selection

Unchanged: self-contained, no fan-out, no screen.

---

## 6. Combined domain confirm / Result screen

Worked example: Software Development (`Python`, `React`) + Project Management (GitHub backend).

```
Install 2 domains to ~/.claude                              (b: back · q: quit)
                                                              (?: help)

  Software Development — 2 technologies selected
  (installs a tech pair — developer and reviewer):
    + Python
    + React

  Project Management — GitHub backend selected:
    + GitHub backend

  Software Development — per-technology standards (2):
    + Python standard
    + React standard

  Software Development baseline (44, pulled in automatically):
    + Flow implementation
    + Flow review
    + Flow testing
    + Flow spec
    + Flow decision
    + Flow tech pair
    + Flow documentation
    + Flow external review
    + Flow git operations
    + Review boundaries
    + Standard judging
    + Build core
    + Build report standards
    + Review core
    + Review report standards
    + Security review lens
    + Test quality review lens
    + Clean code review lens
    + Consistency review lens
    + Compatibility review lens
    + Observability review lens
    + Performance review lens
    + Persistence review lens
    ... and 22 more, one line each in the real preview

  Project Management baseline (3, pulled in automatically):
    + Project manager
    + Standard backlog artifacts
    + Flow project management

  Cross-domain (shared by more than one domain; installed once):
    + Git auth procedure
      required by: Software Development (git operator, baseline),
                   Project Management (GitHub backend)

  55 items total. Nothing has changed yet.

  Also installing (first run only, not counted above):
    CLAUDE.md and the framework's contract schemas.

[DRY RUN] Nothing has changed yet.

Proceed? [Y/n]:
```

*(Arithmetic unchanged from round 5: 5 selected files (2 techs × 2 agents + 1 backend) + 2 per-tech standards + 44 SD baseline + 3 PM baseline + 1 cross-domain = 55. The technologies line displays 2 lines for 2 techs but still counts 4 real agent files, per the round-6 changelog above.)*

**Confirmation tier: safe** — default-Yes, cyan.

---

## 7. Main menu, List, Doctor, Accounts, Uninstall

### Main menu status block

*(Unchanged.)*

```
  Status
    Software Development:    ✓ installed   (2/9 technologies)
    Project Management:      ✓ installed   (GitHub backend)
    Getting Things Done:     not installed
```

### List — three status groups, no domain grouping

**Round 6: restructured entirely.** Not grouped by domain any more — grouped by status, full stop. Every real component (selectable or baseline, whichever domain) appears in exactly one of three groups. `CLAUDE.md`/contracts don't appear here — they're the one first-run-only bundle outside this model (§1).

```
Components — discovered                                      (b: back · q: quit)
                                                               (?: help)   [dim]

Installed
  ✓ Python agent developer
  ✓ Python agent reviewer
  ✓ React agent developer
  ✓ React agent reviewer
  ✓ GitHub backend
  ✓ Flow implementation
  ✓ Flow review
  ✓ Security review lens
  ✓ Git operator
  ✓ Project manager
  ... and 27 more, one line each in the real output

Available
  + Kotlin agent developer
  + Kotlin agent reviewer
  + Rust agent developer
  + Rust agent reviewer
  + Jira backend
  ... and 16 more, one line each in the real output

Diverged
  ! Shell script agent developer
  ! Shell script agent reviewer

  → Diverged items re-sync the next time you run "Install" and choose them.
```

*(Glyphs reuse the base spec's own legend — `✓` green success/installed, `+` blue addition/available, `!` yellow diverged — applied here to a plain listing rather than a preview, which is a new context for them but not a new meaning.)*

### Doctor — tools and accounts only

**Round 6: no component listing at all.** List owns what's installed; Doctor owns whether the environment can actually run it.

```
crucible-hub doctor — ~/.claude                              (b: back · q: quit)
                                                               (?: help)   [dim]

  Required tools
    Git         ok
    GitHub CLI  ok
    jq          ok

  Accounts
    GitHub   ✓ authenticated as octocat (github.com)
    Jira     not authenticated

  Summary: 1 note
    - Jira not authenticated (only relevant if you install the Jira backend)

  Suggested next steps (1):
    1) Accounts → configure Jira
```

### Uninstall — flat list, no domain grouping

**Round 6: matches List's flattening.** Only installed items appear (nothing to group by status here — everything on this screen already is installed); no domain headers.

**Round 7: no blocking-dependents decision screen.** A shared unit still required by something that stays installed is resolved automatically (Kept), and one no longer required by anything is removed automatically (Cascade); both are itemized on the dry run before the confirm prompt. See the round-7 changelog entry at the top of this document for the reasoning and for when to revisit it.

```
Select items to uninstall                                    (b: back · q: quit)
(space: toggle · a: select all · type to filter · enter: confirm)   (?: help)

  [x] React agent developer
  [x] React agent reviewer
  [ ] Python agent developer
  [ ] Python agent reviewer
  [ ] GitHub backend

  2 selected
```

### Accounts

*(Unchanged.)*

```
  GitHub   ✓ authenticated as octocat (github.com)
           used by: Software Development, Project Management (GitHub backend)
  Jira     not authenticated
           used by: Project Management (Jira backend — not installed)
```

---

## 8. Agent-facing mode

*(Unchanged in mechanism from round 5 — `--domains`, `--technologies`, `--pm-backends`; no `--lenses`, since lenses aren't selectable. Display-naming changes in this round don't affect flag spellings, which stay kebab-case/lowercase, matching every existing flag in the base spec.)*

---

## Open questions

- Whether `PHP`/`DevOps`/`GTD`'s capitalization exception (§0-1) should instead be strict mechanical conversion for total consistency — flagged, not settled.
- Whether Uninstall needs type-to-filter once a real system's installed-item count grows — not yet a problem at today's scale.
- The lens-visibility question from round 5 (is there any screen that shows which lenses exist, now that they're never selected) — still open, leaning toward "no, `flow-review`'s own on-demand trigger is enough."
