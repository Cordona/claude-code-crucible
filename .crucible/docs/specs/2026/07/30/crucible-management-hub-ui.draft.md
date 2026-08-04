# Spec: Crucible Management Hub — Terminal UI/UX Contract

**Status:** draft (round 9 — a small, targeted correction pass, not a rewrite. Three independent lens critics reviewed round 8 fresh; two returned CHANGES-NEEDED with a small number of concrete findings, one returned APPROVED with 3 minor suggestions. Round 9 fixes the one real arithmetic/consistency bug those two lenses converged on, plus every narrower finding raised.) **Net effect on round 8's substance:** every mechanism and correction from rounds 1–8 not named below survives unchanged in substance — this is a genuinely small diff, not a rewrite.

**What changed, this round:**
- **The one real bug — Selective install's worked example contradicted its own DEV-SIDE/REVIEWER-SIDE trigger rule.** The checklist selects `python-developer`, `react-developer` (both `{tech}-developer`s) **and** `shell-reviewer` (a reviewer) together — which the shared-vocabulary trigger table says fires **both** triggers, pulling in the **full ten-item conditional-shared tier**. Round 8's confirm screen instead showed only 3 auto-pulled items (`standard-python`, `build-core`, `build-report-standards`), silently dropping all six cross-cutting standards and both REVIEWER-SIDE items — a real arithmetic undercount, not a wording issue. **Resolution chosen:** kept the checklist's existing 3-item selection unchanged (the smaller diff, and it's a more informative worked example precisely *because* it demonstrates both triggers firing together) and corrected the confirm screen to fully itemize all **11** auto-pulled dependencies (`standard-python`, a per-tech-pair dependency, plus the full ten-item conditional-shared tier), each with an accurate "required by" annotation. Recomputed `Total to install` from 7 to **15** (3 selected + 11 auto-pulled + 1 core). Expanded the Result screen to list all 15 installed items by name, per Selective flows' own no-abbreviation rule. Dropped the prior round's "abbreviated for readability" footnote — that framing was excusing an arithmetic undercount, not a legitimate display shortcut.
- **Finding 1 (typed-phrase gate's missing 3rd-attempt text):** the mockup now shows all three attempts explicitly, ending in `Too many incorrect attempts — cancelled. Nothing changed.` — not just prose describing that it happens.
- **Finding 2 (nav-hint column overflow):** measured every mockup header carrying an inline `(b: back · q: quit · ?: help)` hint (exact character counts, not estimates). Confirmed violations at Selective install's confirm/Result screens, Selective uninstall's checklist/blocking-dependents/cascade/Result screens, and Install-all/Uninstall-all's dry-run and Result headers — all now wrapped onto two lines, matching List/Doctor/Accounts' own pre-existing split pattern. The Selective-install checklist header (`Select components to install...`) was re-measured at exactly 80 and needed no change.
- **Finding 3 (HUB_STATUS/HUB_BLOCKED_REASON closed vocabulary):** added an explicit statement in Agent-facing mode declaring the full, closed value set for each field, verified against every occurrence in this document — `HUB_STATUS` ∈ `{ok, blocked}`; `HUB_BLOCKED_REASON` ∈ `{dependents_present, confirmation_required}`. No third value exists anywhere in this draft.
- **Finding 4 (Non-TTY label consistency):** renamed Uninstall-all's "Non-interactive equivalent:" callout to "Non-TTY:" — matching every other flow's heading and the no-flags-wall's own exception wording, which names only "the 'Non-TTY' callouts" (the smaller of the two allowed fixes).
- **Finding 5 (List's un-elided rows):** added a one-line "... (28 more rows...)" note to List's mockup, matching Install-all/Uninstall-all's own elision convention for their bulk previews.
- **Finding 6 (checklist-discard guard's scope):** broadened the "Discard N selected items and quit?" guard to also cover the confirm/dry-run screen immediately following the checklist — both hold the identical not-yet-committed selection, so a habitual `q` is the identical footgun at the identical cost at either point.
- **Finding 7 (reversal-line wording):** replaced "filter to and toggle" (round 8's own fix, which accurately described only the default checklist mechanism) with the mode-neutral **"choose,"** with a one-time note covering both the checklist-toggle and accessible-mode typed-selection mechanisms.
- Everything else — every mechanism, citation, and arithmetic result from rounds 1–8 not named above, including Install-all/Uninstall-all's own already-verified 28+3+2=33/42/44 arithmetic and the two-formula "illustrative worked example" invariant itself — is unchanged in substance.

**Created:** 2026-07-30 (round 7); corrected 2026-07-30 (round 8); corrected 2026-07-30 (round 9)
**Repos in scope:** claude-code-crucible (shell CLI, terminal UI only — no implementation detail)

**Naming note:** `crucible-hub` is used throughout as an illustrative placeholder only. The binary name, install location, and language/runtime are explicitly out of scope here (see Open Questions) and belong to the separate implementation spec. Separately: the underlying today-script this hub fronts is literally named `deploy.sh` in the repo — a pre-existing implementation fact, out of scope to rename. The install/uninstall vocabulary defined in this spec describes only the hub's own UI and is independent of that file's name.

## Goal

Define the complete terminal interaction contract for a management hub CLI that fronts Crucible's existing symlink-based deployment (today: all-or-nothing via `deploy.sh`) with selective install/uninstall, dependency-aware resolution, account management, and an aggregated health view — usable equally by a human at an interactive terminal and by an agent driving it non-interactively, **with zero capability gap between the two** (see the Human/agent parity Constraint). This spec fixes *what the user/agent sees and types* for all nine finalized capabilities; it fixes nothing about how the tool is built.

**The nine finalized capabilities, enumerated for traceability against the sections below:**

1. Selective install
2. Selective uninstall
3. Install all
4. Uninstall all (incl. CLAUDE.md backup restore, including the multiple-backups edge case, and a typed-phrase critical confirmation)
5. Dependency-aware resolution (one shared graph, walked forward for auto-pull, in reverse for blocking-dependents/cascade — core is exempt from this graph entirely; see the Core tier below)
6. List (installed/DIVERGED/available status view, plus core's own presence line) — framed explicitly as a dynamic-discovery result, never a hardcoded list
7. Account management (GitHub / Jira)
8. Doctor (aggregated health check, plus core's own presence line, plus the foregrounded, actionable required-tools check)
9. Dual-mode operation (interactive TTY UX + non-interactive/agent-facing flag-driven form, gated uniformly by the dry-run-then-confirm pattern, with full human/agent parity — no interactive action lacks a flag-driven equivalent). **The interactive side of this dual mode uses zero flag syntax in its own on-screen text — see the Interaction contract's "No flags in the interactive UI" bullet for the exact, corrected scope of that wall.**

*(Note: "nine finalized capabilities" refers to this list of interaction modes and is unrelated to the conditional-shared tier's item count — see the "illustrative worked example" Constraint for why none of the counts anywhere in this document, including "33"/"10"/"42"/"44," are permanent facts.)*

## Non-goals

- **"Explain/show"** (printing a single agent/skill/contract's own description on request) — explicitly cut; not worth the implementation cost. *(This is distinct from the plain-language gloss attached to `Core` wherever it's mentioned in this spec — the persistent `Core:` status line (Main menu, List, Doctor) always carries it, abbreviated on the Main menu during steady-state, full-length during first-run and always on List/Doctor — see Finding 10 (round 8) below for the resolved first-run/steady-state split.)*
- Any **implementation/architecture decision**: file layout, script/language choice, how dependency graphs are computed or stored, how symlink state is diffed, how auth scripts are invoked under the hood, and the exact mechanism by which core-tier and conditional-shared-tier membership are curated (allowlist file? frontmatter metadata tag on each skill/agent?). See the architecture note in the shared vocabulary below (Finding 6 of round 7): this spec asserts the *requirement* that this classification can't be derived from naming pattern, not the mechanism that stores it.
- The **visual theme/palette**, mostly: exact hex values, box-drawing character set, and whether a TUI framework (Bubble Tea/Ink/Textual) is used remain out of scope, as in round 6. **Exception:** the four *semantic* hues fixed by requirement 6 (`+` blue, `-` red, `✓` green, plus `!` yellow and `~` yellow carried over from the daemon-research legend) ARE a first-class, in-scope part of this spec — they are not "pixel-level styling," they are meaning-bearing, exactly like the status words they sit beside. See the Glyph & color legend subsection.
- Exact **command/binary name** and **flag spelling** — illustrative only here (see Open Questions), including the critical-uninstall confirmation flag (illustrated here as `--confirm=UNINSTALL`).
- Reimplementing GitHub/Jira auth — this hub is a thin front over the framework's existing `procedure-git-auth` / `procedure-jira-auth` scripts; it does not define their internals.

## Interaction contract

### Shared vocabulary

- `installed` / `DIVERGED` (installed but symlink no longer matches source) / `available` (not installed) — the three states any **optional** component can be in. Core has only two states of its own — `installed` / `not installed` — displayed separately, never mixed into this three-state vocabulary; see the Core tier bullet below.
- `[ ]` unselected · `[x]` selected · `[!]` selected-but-diverged (re-syncs on install) — checkbox glyphs in interactive multi-select.
- Every mutating action previews as `[DRY RUN]` and is gated by a confirmation drawn from the tier ladder below (see Constraints) — never bypassed by any single interaction below. **The confirmation step is a plain, flag-free prompt in every interactive path** (`Proceed? [Y/n]:`, `Proceed? [y/N]:`, or the typed-phrase critical gate) — the non-interactive equivalent (`--apply`, or `--apply --confirm=UNINSTALL` for the one critical flow) is fully specified only in Agent-facing mode, never mentioned in interactive text. See "No flags in the interactive UI" below.
- **Dependency resolution** (capability 5) is one shared graph-walk, not two features: the *same* dependency graph is walked forward to auto-pull requirements (install) and in reverse to find blocking dependents (uninstall). Every place below that resolves dependencies is invoking this one capability, never re-deriving its own. **Core is not a node in this graph** — it is an implicit root that no walk, forward or reverse, ever reaches; see the Core tier bullet below for the full exemption. The conditional-shared tier (also below) is **not** exempt — those items ARE ordinary graph nodes, resolved by this same walk, including at bulk scale (Install-all/Uninstall-all).
- **The status-summary computation** (installed/DIVERGED/available counts) is one shared computation, rendered at three call sites — Main menu's status block, List's footer, Doctor's "Install state" block — and reused, never independently re-derived. It counts only the **optional units** the hub's discovery scan currently finds — see the "illustrative worked example" Constraint for why this document uses a fixed number (33) as a worked example rather than a claimed permanent fact. Install-all's `New`/`Replace`/`Skip` breakdown (below) is the *same* three-state vocabulary under a transaction-preview framing: `New`=`available`, `Replace`=`DIVERGED`, `Skip`=`installed`-unchanged — **the conditional-shared tier's own counts are always tracked in a separate, explicitly labeled block, excluded from New/Replace/Skip, never folded in** (this is applied consistently at every call site that renders it — see the Selective install fix below, corrected in round 8, and completed in round 9 for the same reason).
- **The foreign-file-at-target write guard** is a universal write-safety check, not a bulk-only one: every symlink write — selective install, selective uninstall, install-all, uninstall-all, and core's own implicit prerequisite install — checks for a foreign (non-framework) file occupying the target path before writing, and refuses to silently overwrite or skip it. Unchanged from round 6.
- **Core is an implicit, always-on tier — never a selectable menu item or flag target — and it is deliberately narrow.** The confirmed core set: `main-thread/CLAUDE.md` + all 11 `flow-*` orchestration skills; `review-boundaries`, `standard-judging`, `standard-backlog-artifacts`; the tech-agnostic operational agents (`git-operator`, `project-manager`, `docs-writer`, `gtd-inbox-writer`, `tech-developer-generator`, `tech-reviewer-generator`, `decision-arbiter`, `review-arbiter`); and every `contracts/*.schema.json`. Nothing here changes in substance — only its rendering does (gloss length on the Main menu now depends on first-run vs. steady-state; see Finding 10, round 8).
- **Conditional-shared tier — NOT core, auto-pulled exactly like any other dependency (e.g. `standard-python`):** `build-core`, `build-report-standards`, `review-core`, `review-report-standards`, and the six cross-cutting standards (`standard-clean-code`, `standard-observability`, `standard-performance`, `standard-security`, `standard-testing`, `standard-persistence`) pull in via exactly two triggers:

  | Trigger | Fires on | Pulls in |
  |---|---|---|
  | **DEV-SIDE** | first `{tech}-developer` **or** `tests-developer` selected | `build-core`, `build-report-standards`, **and** all six cross-cutting standards — together, in one pull (8 items) |
  | **REVIEWER-SIDE** | first reviewer selected (tech **or** lens) | `review-core`, `review-report-standards` (2 items) |

  `tests-developer` alone fully satisfies the DEV-SIDE trigger. **A selection that fires BOTH triggers pulls in the full tier — all ten items, DEV-SIDE's eight plus REVIEWER-SIDE's two — together, not just one side's subset** (round 9: this is the exact rule Selective install's own worked example failed to apply consistently; see the correction below). Unchanged from round 6 in mechanism; the exact item count (ten) is, like every count in this document, an illustrative worked example — see below.

**Architecture note: discoverable vs. curated tier membership.** `{tech}-developer`, `{tech}-reviewer`, `standard-{tech}`, `lens-*-reviewer`, and `tests-developer` are **name-pattern-derivable** — this is exactly how a newly generated tech pair "just appears" in the hub via dynamic discovery (see the Dynamic discovery subsection below), with zero list-maintenance. Core-tier and conditional-shared-tier membership are **NOT** name-pattern-derivable. `standard-clean-code` (conditional-shared) and `standard-python` (optional) are structurally identical by naming convention alone — same `standard-{x}` shape — yet belong to different tiers with different discovery/counting rules. Discovery therefore auto-derives **optional-tier** membership only; core-tier and conditional-shared-tier membership remain an **explicit, curated classification** that discovery does not, and structurally cannot, auto-derive. **The exact mechanism that stores this classification (a manifest/allowlist file the hub reads at startup, vs. a frontmatter metadata tag on each skill/agent file itself) is explicitly deferred to the implementation spec** — this document asserts the requirement (naming pattern alone is insufficient for two of the three tiers) without inventing or silently resolving the storage mechanism. This extends, rather than duplicates, round 6's existing Open Question about keeping the core/conditional-shared enumerations in sync as the framework evolves.

### No flags in the interactive UI (Part A requirement 2)

**The interactive UI never shows CLI flag syntax — `--apply`, `--components`, `--cascade`, `--details`, etc. — in any prompt, menu, confirmation, Result screen, or Doctor suggestion.** Concretely, and applied retroactively to every mechanism round 6 already specified:

- Confirm prompts are now plain: `Proceed? [Y/n]:` / `Proceed? [y/N]:` (never `Proceed with --apply now? [y/N]:`) — see the confirmation-tier table below for which flavor each flow uses.
- The `[DRY RUN]` marker line reads simply `[DRY RUN] Nothing has changed yet.` — round 6's trailing clause `Re-run with --apply to install.` is dropped from the interactive path, because the very next line (the confirm prompt) *is* that re-run, in one step. That clause survives, unchanged, in Agent-facing mode, where a dry-run invocation without `--apply` genuinely does need to tell the caller what to do next.
- Every Result screen's "how to reverse this" line is phrased in interactive-menu vocabulary, never as a flag-bearing command (round 8, Finding 12 — "select" meant two different physical actions in accessible vs. checklist mode, so every reversal line spells out the mechanism). **Round 9, Finding 7:** round 8's own fix — "filter to and toggle" — over-corrected: it accurately named the default checklist's two-step mechanism (filter, then toggle), but described only that mode, not accessible mode's single-step typed selection (type numbers/names, comma-separated). The verb is now the mode-neutral **`choose`**, with a one-time note, stated once here and applying everywhere this wording appears: **"choose" means toggling the matching row(s) in the checklist, or typing the same name(s)/number(s), comma-separated, in accessible mode — whichever mode the user is actually running.** e.g. `→ To reverse: open "Uninstall", choose: python-developer, react-developer, shell-reviewer.` (was `crucible-hub uninstall --components python-developer,react-developer,shell-reviewer --apply`). See each flow's mockup below.
- Doctor's "Suggested next steps" describes each fix by menu/command name, never a flag-bearing command line, using the same mode-neutral `choose` (round 9, Finding 7): e.g. `2) Install → choose: kotlin-reviewer, shell-reviewer, to re-sync (or run "Install all")` (was `crucible-hub install --components kotlin-reviewer,shell-reviewer --apply`). Third-party remediation commands (e.g. `brew install gh`) are **not** a violation of this rule — they are the *external tool's* install command, not this hub's own flag syntax, and stay exactly as shown.
- **The flag-form equivalent of every one of the above remains fully, unchangedly specified in the separate Agent-facing mode section.** Nothing about capability, only presentation, changes.

**Scope of the "hard wall" (round 8, Finding 5 — this was overstated in round 7 and is corrected here):** the wall above governs **interactive prompts, menus, confirmations, Result screens, and Doctor's suggestions** — it does NOT govern the "Non-TTY" callouts threaded through this document (Selective install, Selective uninstall, Uninstall-all, List, Doctor). Those callouts legitimately describe, **in prose, not as an on-screen UI element**, how the separate non-interactive path behaves, and naming a flag token there is the only way to describe that path accurately. Round 7's own text contradicted its own absolute wording twice — the Non-TTY callouts scattered through the document, and Uninstall-all's non-interactive code example sitting physically inside the interactive-flow section before Agent-facing mode even began. The Non-TTY callouts are now an explicit, named exception rather than an unaddressed inconsistency; the misplaced code example is relocated — see Uninstall-all below and Agent-facing mode. **(Round 9, Finding 4: every callout describing this exception is now literally headed "Non-TTY," including Uninstall-all's own confirm-flag callout, which round 8 had left titled "Non-interactive equivalent" — see Uninstall-all below.)**

### Navigation & help (Part A requirements 7, 8, 9)

**[RESEARCH]** I verified the terminal convention this section depends on before adopting it. Across `less`, `man`, `more`, `top`, `htop`, `lazygit`, and `k9s`, `q` is the near-universal single-key **quit-the-whole-program** binding — not "go back one level," not "return to a parent view." `lazygit`'s own docs confirm `?` as its global, context-sensitive help trigger, reachable from anywhere. This is still the current (2025–2026) convention; nothing in the ecosystem has moved away from it.

**Resolution, stated explicitly as the navigation model for this entire hub:**

- **`q` quits the hub entirely, from anywhere** — matching its own label and the universal convention above. There is no confirmation step for `q` on a screen with nothing pending (nothing to lose). **Exception, stated explicitly (round 8, Finding 9; broadened in round 9, Finding 6):** a non-empty pending selection is guarded from the moment it exists until it's either confirmed (written to disk) or explicitly discarded — this spans **both** the checklist screen (at least one item toggled/selected) **and** the confirm/dry-run screen that follows it, which holds the identical pending selection. Pressing `q` at either point asks once — `Discard N selected items and quit? [y/N]` — before exiting; an *empty* checklist's `q`, and `q` on any screen with nothing pending, still exit immediately with no prompt, so the common case pays nothing. **Rationale for extending past the checklist (round 9):** the confirm screen holds the exact same not-yet-committed selection the checklist just built — a habitual `q` there is the identical footgun, at the identical cost (rebuilding a possibly large selection from scratch), so guarding one screen and not its very next sibling would close the gap in the wrong place. This is a deliberate, narrow carve-out from "no confirmation on `q`," not a reversal of it: the spec elsewhere treats cancelling a pending operation as worth a deliberate step (blocking-dependents' own numbered `3) Cancel — remove nothing`), and a user who has toggled 15–20 items losing all of it to a habitual `q` is a real footgun a one-line prompt cheaply prevents. Selection state is still never persisted across invocations — this exception only prevents *silent, instant* loss within the same session, it doesn't add durability.
- **`b` / `back` goes back exactly one level**, from any non-root screen. It never jumps further than one level.
- **There is no third "jump straight to root" key.** The hub's nesting is shallow by design — at most 2–3 levels (e.g. Main → Install → checklist → confirm; Main → Accounts → sub-action) — so repeated `b` presses reach the main menu naturally within one or two keystrokes.
- **This retires round 6's numbered `Back`/`Cancel` menu-item convention for every submenu that has somewhere to go back to** (Accounts no longer has a numbered `5) Back` row) **and retires the checklist's old `q`-cancels-and-returns convention** (that meaning now belongs to `b`, freeing `q` to mean what it says everywhere, subject to the non-empty-selection exception just above).
- **The Main menu keeps its numbered `8) Exit`** as its own last enumerated choice — never a "Back" (there is nowhere to go back to from root) — alongside the global `q` accelerator. Both work.
- **Domain-specific numbered choices that happen to include a "cancel this operation" option** (blocking-dependents' `3) Cancel — remove nothing`; multiple-backups' `4) Restore none`) are **not** navigation and are **not** retired — they are substantive decision branches enumerated alongside their siblings, staying exactly as round 6 specified. The global `b`/`q` hint is additionally available on these screens (pressing `b` produces the same effect as choosing the numbered cancel option).
- **Exception — the one free-text field in this hub (round 8, Finding 8):** the Uninstall-all critical gate's "Type UNINSTALL to confirm" prompt is a free-text input field, so during it — and only during it — `b`, `q`, and `?` are **not** interpreted as navigation; they are literal characters contributing to a (likely incorrect) typed attempt. Only pressing Enter on an empty line cancels. See the Uninstall-all mockup below for the on-screen feedback this produces.
- **Exception — the help screen (round 8, Finding 17):** viewing help is a temporary, read-only overlay, not a normal navigable screen. **ANY key while help is showing — including `q` — closes help and returns to the calling screen; it never quits the hub.** This is a deliberate, named carve-out from the global "`q` quits from anywhere" rule, not a silent contradiction: it is strongly precedented (`vim`'s `:help` buffer, where `q` closes the help window rather than quitting `vim`; pager-style help screens behave contextually the same way). Without this exception, pressing `q` on the help screen would be genuinely ambiguous between "quit the hub" (the global rule) and "close help" (the screen's own text) — this states which wins, and why.

**Global `?` help (Part A requirement 7):** reachable from every screen, prints a static, category-grouped command reference, entirely dimmed (see the Glyph & color legend below for the dimming convention), and returns to whatever screen was showing on any keypress — including `q` (see the help-screen exception immediately above):

```
Crucible Management Hub — Help                                          [dim]

  Navigation
    ?              show this help
    b, back        go back one step (repeat to reach the main menu)
    q, quit        quit the hub, from anywhere (except: while viewing this
                   help screen, any key — including q — just closes help)

  Actions
    list           installed vs available components
    doctor         full environment + install health check
    accounts       manage GitHub / Jira authentication
    install all    install every discovered component
    install        select specific components to install
    uninstall all  uninstall everything (critical action, typed confirmation)
    uninstall      select specific components to uninstall

  Press any key to return.
```

Every mockup below (dimmed, per requirement 9) shows a `(b: back · q: quit · ?: help)` hint line, **with one true exception** (round 8, Finding 11 — round 7 claimed this universally and it wasn't yet true): the Uninstall-all typed-phrase field, where those keys are literal input rather than navigation (see the exception above). **(Round 9, Finding 2: several of these hint lines, once measured, pushed their header past this document's own 80-column floor; each is now wrapped onto its own line(s), matching the pattern List/Doctor/Accounts already established — see each mockup below.)**

### Glyph & color legend (Part A requirement 6)

| Glyph | Color | Meaning | ASCII fallback | Where it's used |
|---|---|---|---|---|
| `✓` | green | success / installed / authenticated | `[ok]` | Result screens, Main menu/List/Doctor's positive states |
| `✗` | red | genuine failure | `[fail]` | required-tool missing, blocked write, resolution failure — **never** "not authenticated" (see below) |
| `!` | yellow | warning / diverged / degraded-but-actionable | *(already ASCII)* | diverged items, non-blocking missing optional tool, Main-menu problem banner |
| `+` | blue | new / will-be-added | *(already ASCII)* | preview-time additions (New block, auto-pulled dependencies) |
| `-` | red | will-be-removed | *(already ASCII)* | preview-time removals (Remove block) |
| `~` | yellow | will-be-re-synced | *(already ASCII)* | preview-time Replace block |
| `→` | cyan | informational / advisory | `->` | the next-step and reverse-action lines on Result screens |
| `[dim]` | — | secondary/low-emphasis text | *(no fallback needed — dimming is an ANSI attribute, stripped identically by `NO_COLOR`)* | nav hints, help screen, shortcuts |

Notes:

1. Only `✓`, `✗`, and `→` are true non-ASCII Unicode glyphs and need a locale-based ASCII fallback — `!`, `+`, `-`, and `~` are already plain ASCII characters. Round 6's fallback Constraint only defined `✓ → [ok]`; this completes it with `✗ → [fail]` and `→ → "->"`.
2. `→` prefixes the advisory lines on every Result screen — the "next read-only step to try" line and the "how to reverse this" line — distinguishing informational text from the `✓` receipt lines above it.
3. The daemon-research legend's `*` (yellow hint) glyph is dropped, not carried forward — requirement 9 already assigns "hint/shortcut" text its own channel (dimming), and a second glyph-based hint marker would be redundant.
4. `✗`/red is reserved for genuine failures and is never applied to "not authenticated" anywhere in this document. `authenticated` renders as `✓ authenticated` (green); `not authenticated` renders as plain, uncolored text with no glyph — everywhere, including inside Doctor's own per-line accounts block. The only place "not authenticated" is grouped alongside genuine problems is Doctor's `Summary:` bullet list, and even there it's a plain dash bullet, never an `✗`-prefixed line.

**Research note on the color mapping itself — corrected for round 8 (Finding 15).** [RESEARCH, re-verified] Terraform (`git diff`-style green-create/yellow-change/red-destroy) and Pulumi (green `+` in both `preview` and `up`) were both re-checked, and both use **green** for "will create," with **no distinct color for the preview moment versus the result moment** — Terraform and Pulumi are comfortable using the same hue for "will happen" and "happened." **This means neither citation supports round 7's argument that a preview-vs-result distinction independently justifies diverging from green for `+`** — if anything, the cited precedents show that distinction being handled fine *without* a color change. Round 8 corrects the framing rather than the color: **blue for `+` was the human's own explicit, stated requirement for this spec (Part A requirement 6), not a choice this document is second-guessing** — it stays blue. What changes is the justification offered: this is stated plainly as **a deliberate divergence from the git-diff/terraform-plan/pulumi-preview convention (green-for-add)**, made by explicit human decision, not something Terraform or Pulumi's own behavior validates. The one *independent* rationale that does stand on its own, without needing external convention behind it: `✓` (success/result) is already green in this legend, and reusing green for both `+` (preview, not-yet-true) and `✓` (result, true) would blur this spec's own two-moment distinction (preview vs. result) — an internally-motivated reason, offered on its own merits, not as something Terraform/Pulumi are claimed to back.

### Dependency / tool-availability check (Part A requirement 3)

**Decision: keep round 6's lazy banner-and-Doctor model. Do NOT add a blocking pre-launch dependency gate**, despite the direction proposal's mockup 1 showing one (`Crucible Management Hub — checking environment...` before the menu ever renders, with a blocking `Continue anyway? [y/N]`). That mockup is rejected here, not adopted.

**[RESEARCH]** I checked current convention for exactly this shape of decision — does a CLI block entry pending a dependency check, or check lazily, on-demand, at the point a specific command actually needs the resource? The clearest, most directly comparable precedent is Docker's own CLI: `docker --version`, `docker help`, and any daemon-independent subcommand work with **no daemon running at all**; the "Cannot connect to the Docker daemon" error surfaces only when a command that genuinely needs the daemon (e.g. `docker run`) is invoked — never at CLI startup, never gating unrelated commands. This hub's own equivalent unrelated commands are `List` and `Doctor` (read-only; neither needs `gh` or `gpg` to function) — a user who launches the hub only to check `List` or run `Doctor` should never be forced through a `gh`-availability gate to get there, exactly as a `docker ps` shouldn't be blocked by an unrelated daemon check it doesn't need.

**[RESEARCH, corrected for round 8 — Finding 13]** Round 7 additionally claimed this was "the general shape clig.dev's own philosophy points toward as well." I re-checked clig.dev directly for a specific, quotable line backing lazy-vs-blocking checks and found none — its closest relevant content is a general composability statement ("whatever software you're building… your software will become a part in a larger system — your only choice is over whether it will be a well-behaved part"), which doesn't itself address whether a CLI should check dependencies at startup or on-demand. That was an overclaim; round 8 drops the clig.dev attribution for this specific decision. The Docker precedent above is directly on-point and doesn't need borrowed support to carry this decision.

**Resolution:** requirement 3 (a foregrounded, actionable required-tools check) is satisfied by strengthening the two surfaces round 6 already had, not by adding a new screen:

1. **The Main-menu banner** (round 6, unchanged in mechanism) now names the remediation path explicitly rather than only pointing at Doctor: `! Doctor found 1 problem — required tool "gh" not found (needed for GitHub account management). Run "Doctor" for remediation steps. Some actions may fail until resolved.` The menu stays fully usable for read-only actions (`List`, `Doctor`); mutating actions that need the missing tool warn again at their own confirm point.
2. **Doctor's "Required tools" block** (round 6 only showed bare `ok`/`missing`) now carries actual, actionable remediation per missing tool — see the Doctor mockup below.

This is a genuine design disagreement with the direction proposal's mockup 1, stated explicitly rather than silently reconciled.

### Dynamic discovery (Part A requirement 4)

The hub scans the framework's real installed/available structure at need — no hardcoded component list ships with the hub. Two distinct discovery rules apply (see the architecture note above): **optional-tier** membership is auto-derived from naming pattern (`{tech}-developer`, `{tech}-reviewer`, `standard-{tech}`, `lens-*-reviewer`, `tests-developer`); **core-tier and conditional-shared-tier** membership is a curated classification discovery cannot infer from name shape alone.

**[RESEARCH]** whether a directory-scan-backed picker at this bounded scale (~33–44 items) warrants a visible "Scanning..." progress indicator, or should render instantly and silently. I checked the convention `fzf`/`ripgrep`-backed interactive pickers use at comparable and larger scales: both operate as effectively instantaneous local filesystem operations at this item count. This matches Jakob Nielsen's long-established response-time thresholds (confirmed current): **under ~0.1 seconds reads as instantaneous and needs no feedback at all; feedback becomes necessary only past roughly 1 second, mandatory past 10.** A local scan over a few dozen files is comfortably under 0.1s on any modern filesystem.

**Resolution, corrected for round 8 (Finding 16) — a measured, threshold-based rule, not an absolute one:** the expectation at this scale is that a scan-and-diff renders effectively instantly (sub-100ms), matching the research above, and no screen shows a visible indicator for that normal case. **This is a performance expectation this UI-only spec states, not a guarantee it can enforce** — a real discovery scan here isn't a flat directory listing; it also diffs against source to detect DIVERGED state and resolves the dependency graph, a compound operation that could plausibly exceed the "instantaneous" threshold on a slower filesystem, a much larger framework instance, or a network-mounted home directory. So: **if a scan+diff genuinely exceeds roughly 1 second in practice, the screen may show a minimal `Checking...` line rather than freezing silently with no feedback** — consistent with this spec's own existing convention that spinners/progress indicators are reserved for genuinely long operations (dependency resolution, install/uninstall writes), not withheld from every screen regardless of how long it actually takes. What the direction proposal's mockups correctly captured is that the counts themselves should read as *discovered*, not hardcoded — that's preserved via footer language (`33 discovered` rather than a bare `33 total`), independent of whether a `Checking...` line ever appears.

**One consistent caching rule, stated once, for the whole hub:** a discovery scan result is captured once per screen-render and reused for that screen's entire lifetime — it is never re-scanned mid-interaction (e.g. while the user is typing into a type-to-filter box), and is invalidated only by (a) a completed mutating action, or (b) an explicit refresh (re-entering the screen from the menu).

### The "illustrative worked example" invariant (round 8 — corrected arithmetic, Finding 1)

**Every specific count anywhere in this document — 33 optional units, 10 conditional-shared items, 42/44 bulk totals, and every arithmetic "count check" footnote — is ONE internally-consistent worked example of what a real discovery scan might currently return, never a permanent hardcoded constant.** A different real system, at a different point in the framework's growth, will discover a different number. What must hold, regardless of the number discovery actually returns on any given system, is the **relationship** — stated as **two** formulas, not one, because round 7's single formula silently assumed nothing is ever skipped, which is only true for full-removal:

- **Always true:** `New + Replace + Skip = discovered-optional-count` (every optional unit is in exactly one of these three buckets).
- **Install-type flows (Selective install, Install-all):** `(New + Replace) + conditional-shared-pulled-in + core (0 or 1) = total-acted-on-count`. **`Skip` is explicitly excluded** — an item that's already installed and unchanged is never "attempted," so it never counts toward the total. (Round 7's formula instead added the full `discovered-optional-count`, including `Skip`, which is why plugging in Install-all's own numbers gave 33+10+1=44 against an actual total of 42 — the 2 skipped items were being double-counted as both "not New/Replace" and "acted on.")
- **Full-removal (Uninstall-all):** `discovered-optional-count + conditional-shared-count + core = total-acted-on-count`. Nothing is "skipped" when removing everything — every discovered optional item, every conditional-shared item, and core are all acted on — so this formula correctly uses the full discovered count, not a New/Replace-style subset.

The arithmetic-verification footnotes threaded through the mockups below remain in this document because they remain valuable — they prove *this particular worked example* is internally self-consistent, catching the exact class of miscount round 6 itself once had. They verify the worked example is coherent; they do not assert it as a system fact.

---

### Main menu

```
Crucible Management Hub                                     target: ~/.claude

  Status
    Core:        ✓ installed    (framework prerequisite)
    Components:  12/33 installed · ! 2 diverged
    GitHub:      ✓ authenticated as octocat
    Jira:        not authenticated

  1) List         — installed vs available components
  2) Doctor       — full health check
  3) Accounts     — GitHub / Jira
  4) Install all
  5) Install      — select specific components
  6) Uninstall all
  7) Uninstall    — select specific components
  8) Exit

  Type a number, or '?' for help                                        [dim]
> _
```

*(Menu order per Part A requirement 5: informational/read-only first (`List`, `Doctor`, `Accounts`), then constructive (`Install all`, `Install`), then destructive (`Uninstall all`, `Uninstall`), `Exit` last. Status block is vertical, labeled lines — Part A requirement 1.)*

**Core gloss — resolved, first-run vs. steady-state (round 8, Finding 10 — this reverses round 7's "abbreviate everywhere" call):** round 7 abbreviated the Core gloss on the Main menu unconditionally, reasoning it was the highest-*frequency* screen. That reasoning conflated "visited often" (a steady-state property) with "seen first" (a brand-new user's very first exposure) — the opposite case matters more here: the Main menu is also the *lowest-information* exposure point at exactly the moment a first-time user most needs the explanation, since they may run "Install all" once and never visit List/Doctor at all. **Resolved behavior:** during genuine first-run (core not yet installed), the Main menu's `Core:` status line carries the **full** gloss, piggybacked onto the existing first-run hint message so no new UI element is needed: `Core: not installed (framework prerequisite; shared foundation skills, standards & operational agents every tool depends on)`. Once core is installed (steady-state — the far more common state a returning user/agent actually sees), the Main menu reverts to the **abbreviated** `(framework prerequisite)` form, on the reasoning that the user has by then already encountered the full explanation at least once. List and Doctor keep the fuller gloss unconditionally, regardless of first-run/steady-state, since they're screens a user consults *for* detail.

**States:**
- *First-run (nothing installed, core not yet present):* `Core: not installed (framework prerequisite; shared foundation skills, standards & operational agents every tool depends on)` (plain, no glyph — this is an expected state, not a problem); `Components: 0/33 installed`; a hint line appears below the menu: `Nothing installed yet — try "Install all" or "Doctor" first. The first install action will also install core automatically.`
- *Partial adoption (steady-state):* as shown above — abbreviated Core gloss.
- *Fully installed:* `Components: 33/33 installed`; item 4 may read `Install all (up to date)`.
- *Diverged present:* the `Components:` line carries the `!` warning glyph and count, as shown; a warning line appears below the menu: `! 2 installed items no longer match source — run "Install" and select them to re-sync (see "List" for details).`
- *Error (e.g. Doctor found a missing required tool):* a banner appears **above** the Status block: `! Doctor found 1 problem — required tool "gh" not found (needed for GitHub account management). Run "Doctor" for remediation steps. Some actions may fail until resolved.` The menu stays usable for read-only actions; mutating actions that need the missing tool warn again at their own confirm point. **No blocking pre-flight gate exists — see the Dependency/tool-availability check subsection above for why.**

**Non-TTY fallback:** unchanged from round 6 — the menu never renders off a non-TTY stdin; the tool prints usage and exits with a usage error directing to the flag-driven commands.

**Design note — numbered single-select menus are deliberate, not a lesser fallback:** unchanged from round 6's rationale. These menus no longer enumerate a numbered `Back`/`Exit`/`Cancel` item as one of their own choices (except the Main menu's own `8) Exit`) — that role is carried by the global, dimmed `b: back · q: quit · ?: help` hint shown on every non-root screen instead (with the two named exceptions above — the typed-phrase field and the help screen itself).

---

### Selective install

Selective install and Install-all (below) share **one preview-and-confirm mechanism** — Install-all is the select-all case of the same computation, always rendering the `New`/`Replace`/`Skip` breakdown; selective install renders the identical breakdown and additionally annotates auto-pulled dependencies whenever the selection is a strict subset of everything discovered.

```
Select components to install                       (b: back · q: quit · ?: help)
(space: toggle · a: select all · type to filter · enter: confirm)          [dim]

  [x] python-developer               available
  [ ] kotlin-developer                already installed
  [x] react-developer                available
  [!] shell-reviewer                  installed, DIVERGED — select to re-sync
  [ ] flow-testing                    available

  3 selected
```

*(Round 8, Finding 3: the checklist marks `python-developer`, `react-developer` `[x]` and `shell-reviewer` `[!]` — the same 3 items the Result screen below installs — never `kotlin-developer`, which is already-installed and non-diverged; selecting it would show up as a `Skip`, contradicting the confirm preview's `Skip: 0` a few lines down. Round 9: this selection is deliberately kept unchanged — it fires **both** the DEV-SIDE trigger (`python-developer`, `react-developer`) and the REVIEWER-SIDE trigger (`shell-reviewer`) at once, which is exactly what makes it a useful worked example of the shared-vocabulary trigger table above; see the corrected confirm screen below for the arithmetic this actually implies.)*

*(Note on this and the Install-all mockup below: both examples are captioned "first install ever" — meaning core hasn't been installed by this hub yet — while simultaneously showing rows already `installed`/`DIVERGED`. This isn't a contradiction: the legacy `deploy.sh` this hub fronts may already have placed some symlinks before this hub — and the core/conditional-shared concept — existed. Unchanged from round 6.)*

*Filtering (large lists):* typing narrows the visible rows to those matching the typed substring, matching `fzf`/`gh` interactive-picker conventions; backspace/esc clears the filter. Per the Dynamic discovery subsection above, the filter never re-triggers a scan.

then, on confirm (first install ever — core not yet present):

```
Install 3 selected + 11 auto-pulled (+ core, first run only) to ~/.claude
                                                            (b: back · q: quit)
                                                            (?: help)

  Framework prerequisite (first run only — not a selectable row above):
    + core — shared foundation skills, standards & operational agents every tool depends on; not yet installed

  Auto-pulled dependencies (selected items require these; pulling them in too —
  tracked separately, never folded into New/Replace/Skip below):
    + standard-python           required by: python-developer
    + build-core                required by: python-developer, react-developer
    + build-report-standards    required by: python-developer, react-developer
    + standard-clean-code       required by: python-developer, react-developer
    + standard-observability    required by: python-developer, react-developer
    + standard-performance      required by: python-developer, react-developer
    + standard-security         required by: python-developer, react-developer
    + standard-testing          required by: python-developer, react-developer
    + standard-persistence      required by: python-developer, react-developer
    + review-core               required by: shell-reviewer
    + review-report-standards   required by: shell-reviewer

  New:     2 items   (available → will be installed)
  Replace: 1 item    (DIVERGED → will be re-synced)
  Skip:    0 items   (identical, no change)

  Total to install: 15 (3 selected + 11 auto-pulled + core)

[DRY RUN] Nothing has changed yet.

Proceed? [Y/n]:
```

*(Round 9 — the main correction: this selection fires **both** the DEV-SIDE trigger (`python-developer`, `react-developer` are `{tech}-developer`s) and the REVIEWER-SIDE trigger (`shell-reviewer` is a `{tech}-reviewer`), which the shared-vocabulary trigger table says pulls in the **full ten-item conditional-shared tier**, not a 3-item subset. New = 2 (`python-developer`, `react-developer`, both `available`); Replace = 1 (`shell-reviewer`, `DIVERGED`); Skip = 0 — unchanged from round 8, still correct, since neither auto-pulled category folds into this breakdown. Auto-pulled = 11: `standard-python` (a per-tech-pair dependency of `python-developer` specifically, not part of the conditional-shared tier) + the full ten-item conditional-shared tier (eight DEV-SIDE items: `build-core`, `build-report-standards`, and the six cross-cutting standards; two REVIEWER-SIDE items: `review-core`, `review-report-standards`). Per the install-flows formula: `(New 2 + Replace 1) + 11 auto-pulled + 1 core = 15`, matching "Total to install: 15." Round 8's version undercounted this at 7 by showing only 3 of the 11 auto-pulled items — missing all six cross-cutting standards and both REVIEWER-SIDE items entirely — a real arithmetic bug, not a wording issue. Corrected here by fully itemizing all 11, per Selective flows' own rule that they always fully itemize, never eliding with an "... N more" device the way Install-all/Uninstall-all's bulk previews do. The prior round's footnote describing the 3-item list as "abbreviated for readability" is dropped — that framing was excusing an arithmetic undercount, not describing a legitimate display shortcut.)*

**Confirmation tier: safe** — default-Yes, cyan (see the confirmation-tier table in Constraints) — purely additive, trivially reversible.

then, after confirming (the **Result** screen for a small selective set — itemized and checkmarked):

```
Installed 15/15 items to ~/.claude:                        (b: back · q: quit)
                                                             (?: help)
  ✓ core (installed — framework prerequisite)
  ✓ python-developer
  ✓ react-developer
  ✓ shell-reviewer (re-synced)
  ✓ standard-python
  ✓ build-core
  ✓ build-report-standards
  ✓ standard-clean-code
  ✓ standard-observability
  ✓ standard-performance
  ✓ standard-security
  ✓ standard-testing
  ✓ standard-persistence
  ✓ review-core
  ✓ review-report-standards

  → Run "Doctor" to verify, or "List" to see the updated state.
  → To reverse: open "Uninstall", choose: python-developer, react-developer, shell-reviewer.
  (core is never removed by a selective uninstall — see the Core tier)
```

*(Convention stated once here, applying to every Result screen hereafter, unchanged from round 6: the `N/N` denominator counts only items attempted, never items skipped as already-up-to-date. Round 9: itemized list recomputed to 15 names, matching the corrected "Total to install: 15" above — 1 core + 3 selected + 11 auto-pulled = 15.)*

**`b` from a Result screen (round 8, Finding 11):** a Result screen is a terminal, post-completion display. Pressing `b` here — like pressing Enter/any key to continue — returns to the **calling menu** (the menu that launched this action), **never** to a now-stale checklist reflecting a selection that's already been acted on. This is stated once here and applies to every Result screen in this document.

On every **subsequent** install action, core is already present: neither the preview's "Framework prerequisite" section nor the Result screen's `✓ core (...)` line appears at all — not shown as zero, simply absent.

**States:**
- *Empty (everything already installed):* skip the checklist entirely — `Nothing to install — every component is already installed. Try "Uninstall" or "List".`
- *Partial adoption:* as shown above.
- *Fully installed:* only `DIVERGED` items are meaningfully selectable (re-sync); the list is short or empty per the empty-state rule above.
- *Diverged:* marked `[!]` with the annotation `installed, DIVERGED — select to re-sync`.
- *Error (dependency graph broken):* abort **before** showing the checklist — `! Could not resolve dependencies for "python-developer": skill "standard-python" not found in source. Nothing changed. See "Doctor" for details.`

**Accessibility fallback (`--accessible`, opt-in — see Constraints):** unchanged in mechanism from round 6 — a static numbered list with typed, comma-separated selection, still fully viable at 33+ items:

```
Select components to install (accessible mode — type numbers or names, comma-separated):

  1) python-developer               available
  2) kotlin-developer                already installed
  3) react-developer                available
  4) shell-reviewer                 installed, DIVERGED — select to re-sync
  5) flow-testing                    available
  a) all available

Enter selection (e.g. "1,3" or "python-developer,react-developer"):
```

**Non-TTY:** the only path to a selective install without a TTY is the agent-facing flag form — see Agent-facing mode below (`--components a,b --apply --non-interactive`); the checkbox widget is never attempted. *(This callout, and every "Non-TTY" callout below, is prose describing the separate non-interactive path — not an on-screen UI element — and is explicitly exempt from the no-flags wall above; see Finding 5.)*

---

### Selective uninstall

Selective uninstall and Install-all (below) likewise share one preview-and-confirm mechanism.

```
Select components to uninstall                             (b: back · q: quit)
                                                                     (?: help)
(space: toggle · a: select all · type to filter · enter: confirm)          [dim]

  [x] python-developer
  [ ] kotlin-developer
  [x] standard-python

  2 selected
```

Core is never a candidate in this list or in the resolution below it — exempt from the dependency-cascade graph entirely (see the Core tier).

blocking-dependents case, on confirm:

```
! Cannot remove "standard-python" — still required by:       (b: back · q: quit)
                                                               (?: help)
    - python-developer (installed)

  Choose:
    1) Cascade — also remove python-developer (and anything else that needs it)
    2) Skip "standard-python", remove the rest
    3) Cancel — remove nothing

  Select [1-3]:
```

if cascade is chosen:

```
Also removing (cascade — no longer needed once "standard-python" is gone):
                                                            (b: back · q: quit)
                                                            (?: help)
  - python-developer     (declared: standard-python)

Total to uninstall: 2

[DRY RUN] Nothing has changed yet.

Proceed? [y/N]:
```

**Confirmation tier: dangerous** — default-No, yellow (see the confirmation-tier table in Constraints) — removal carries real risk (the dependents-block/cascade mechanism, the foreign-file guard).

then, after confirming (Result screen, itemized, same pattern as Selective install):

```
Uninstalled 2/2 items from ~/.claude:                       (b: back · q: quit)
                                                             (?: help)
  ✓ standard-python
  ✓ python-developer

  → Run "Doctor" to verify, or "List" to see the updated state.
  → To reverse: open "Install", choose: standard-python, python-developer.
```

**States:** unchanged from round 6 in substance — *Empty*, *Partial/fully installed*, *Diverged item selected*, *Error (inconsistent dependency data)*, *Core exemption* — see round 6's wording, with all interactive text re-run through the "no flags" rule above.

**Non-TTY:** same rule as install — flag-driven only (`--components`, `--cascade`, `--apply`, `--non-interactive`); a blocked removal without an explicit `--cascade` flag fails loudly rather than assuming an answer.

---

### Install-all / Uninstall-all

*(Menu labels say "Install all"/"Uninstall all"; prose uses "Install-all"/"Uninstall-all" as the hyphenated feature name; mockups use `Install ALL`/`Uninstall ALL` for bulk-scale emphasis — unchanged three-surface convention from round 6.)*

Install-all, dry run (first install ever — core not yet present):

```
Install ALL to ~/.claude                                    (b: back · q: quit)
                                                             (?: help)

  Framework prerequisite (first run only): core will also be installed.

  Your existing CLAUDE.md will be backed up first:
    ~/.claude/CLAUDE.md → ~/.claude/CLAUDE.md.backup.2026-07-30T14-22-01Z

  New:     28 items  (available → will be installed)
    + python-developer
    + python-reviewer
    + standard-python
    ... (25 more, one line each in the real preview)

  Replace: 3 items   (DIVERGED → will be re-synced)
    ~ kotlin-reviewer
    ~ shell-reviewer
    ~ standard-kotlin

  Skip:    2 items   (identical, no change)
    = kotlin-developer
    = standard-shell

  Framework dependencies (10, pulled in automatically; not part of New/Replace/Skip above):
    + build-core
    + build-report-standards
    ... (8 more, one line each in the real preview)

  42 components total (28 new + 3 re-synced + 10 framework dependencies + core). Nothing has changed yet.

Proceed? [Y/n]:
```

**Confirmation tier: safe** — default-Yes, cyan. **Rationale (see the confirmation-tier table in Constraints):** Install-all is still purely additive and reversible via the printed inverse "Uninstall all" invocation — the same reasoning as Selective install — but it is deliberately kept behind its full itemized dry-run preview above so consent stays fully informed even at a default-Yes prompt.

*(Every specific count above — 28, 3, 2, 10, 42 — is one illustrative worked example, per the "illustrative worked example" Constraint; the arithmetic, per the install-flows formula above: `(28 New + 3 Replace) + 10 conditional-shared + 1 core = 42`, with Skip's 2 items correctly excluded — verified as internally consistent for this example. Unchanged from round 8 — independently re-verified correct, not touched in round 9.)*

then, after confirming — **default Result screen is a summary line**:

```
Installed 42/42 attempted items to ~/.claude                (b: back · q: quit)
                                                             (?: help)
(28 new, 3 re-synced, 10 framework dependencies, 1 core-bootstrap);
2 items already up to date were not counted in that total.

  → Run "Doctor" to verify, or "List" to see the updated state.
  → To reverse: choose "Uninstall all".

Show details? [y/N]:
```

*(Reusing round 6's own "Show details?" phrasing throughout this document, for consistency.)*

Answering "yes" expands to the full itemized form — **round 8, Finding 2: recomputed to sum correctly.** Round 7's version showed only 4 named lines + "31 more" = 35, undercounting the stated 42/42 total by 7. Recomputed cleanly: 4 named + **38 more** = 42:

```
Installed 42/42 attempted items to ~/.claude                (b: back · q: quit)
                                                             (?: help)
(28 new, 3 re-synced, 10 framework dependencies, 1 core-bootstrap);
2 items already up to date were not counted in that total:
  ✓ core (installed — framework prerequisite)
  ✓ python-developer
  ✓ standard-python
  ... (38 more, one checkmarked line each)
  ✓ tests-developer

  → Run "Doctor" to verify, or "List" to see the updated state.
  → To reverse: choose "Uninstall all".
```

*(Show your work: 4 named lines shown explicitly (`core`, `python-developer`, `standard-python`, `tests-developer`) + 38 elided = 42, matching the header's own `42/42`. Any other named/elided split that sums to 42 is equally valid — this is the one round 8 uses. Unchanged in round 9.)*

Uninstall-all — **the critical-tier typed-phrase confirmation, corrected for arithmetic and friction gaps in round 8 (Findings 6–8, 11, 18):**

```
Uninstall ALL from ~/.claude                                (b: back · q: quit)
                                                             (?: help)

  This will remove 33 discovered components, 10 framework dependencies, and
  core (the framework's own foundation).

  Remove: 33 items, plus 10 framework dependencies, plus core as the final step
    - python-developer
    - python-reviewer
    - standard-python
    ... (30 more, one line each in the real preview)

  Framework dependencies (10, no longer needed once nothing depends on them):
    - build-core
    - build-report-standards
    ... (8 more, one line each in the real preview)

    - core (removed last, as the explicit final step of this flow)

  A backed-up CLAUDE.md was found and will be restored:
    CLAUDE.md.backup.2026-07-15T09-03-44Z → CLAUDE.md

44 components total. Nothing has changed yet.

  This removes core, the framework's own foundation — a full restore to your
  exact prior state is not guaranteed.

Type UNINSTALL to confirm, or press Enter on an empty line to cancel:
> _
```

*(Every count above — 33, 10, 44 — is one illustrative worked example. Per the full-removal formula above: `33 discovered + 10 conditional-shared + 1 core = 44`, matching "44 components total" — nothing is skipped when removing everything, so this is the formula that applies here, not the install-flows one used above. Unchanged from round 8 — independently re-verified correct, not touched in round 9.)*

**Round 8, Finding 7 — the on-screen reason:** the line `This removes core... not guaranteed` is now shown unconditionally, regardless of which backup scenario (single clean backup, shown here, or the multiple-backups edge case) is being illustrated — the Constraints table's own rationale for this being the one critical-tier flow (core removal; restoration isn't always deterministic) now appears on the screen the user actually sees, not only in this document's prose.

**Round 8, Finding 8 — this one field does not follow the global nav-hint model shown above it:** while this typed-phrase prompt is active, `b`, `q`, and `?` are **not** interpreted as navigation — they are literal characters contributing to a (likely incorrect) typed attempt. Only pressing Enter on an empty line cancels. Each wrong attempt re-prompts with feedback, and — **round 9, Finding 1 — the 3rd failed attempt's own on-screen text, missing in round 8, is now shown explicitly:**

```
Type UNINSTALL to confirm, or press Enter on an empty line to cancel:
> uninstall
Not recognized. 2 attempts remaining.
> uninstal
Not recognized. 1 attempt remaining.
> nope
Too many incorrect attempts — cancelled. Nothing changed.
```

*(Round 9: round 8 showed only the 1st wrong attempt (`Not recognized. 2 attempts remaining.`) and then a bare prompt, leaving what happens after the 3rd failure described only in prose below, never shown on-screen. All three attempts and the final cancellation message are now shown explicitly.)*

**Confirmation tier: critical** — no default, red `WARNING:`-class prompt, typed exact phrase, **3 attempts then cancels automatically — citing `sudo`'s own default `passwd_tries=3` setting (round 8, Finding 18; round 7's "reference daemon" citation is retired — it appeared nowhere in that round's own Sources list and wasn't independently verified).** **Rationale, stated explicitly:** Uninstall-all is the one flow where the safe/dangerous tiers don't fit — it removes core, the framework's own foundation, and its own multiple-backups edge case means the exact prior state isn't always deterministically restorable. **This gate supplements the itemized dry-run preview above; it does not replace it:** the full `Remove:`/`Framework dependencies:` itemization still prints in full — only the *final* confirmation step (round 6's plain `[y/N]`) is upgraded to the typed phrase for this one flow.

**Non-TTY (round 9, Finding 4 — renamed from "Non-interactive equivalent" to match every other flow's heading, since the no-flags-wall's exception in the Interaction contract names only "the 'Non-TTY' callouts"):** see Agent-facing mode below — the flag-driven form requires an explicit confirming flag (`--confirm=UNINSTALL`) alongside `--apply --non-interactive`; absent it, the command fails loud rather than silently assuming consent. *(Round 8, Finding 5: round 7's actual non-interactive code example sat here, physically inside the interactive-flow section, before Agent-facing mode began — the one place this document's own "no flags in interactive UI" wall was itself violated. It's relocated below, matching how every other flow's non-interactive form is handled.)*

**[RESEARCH, corrected for round 8 — Finding 14]** grounding this shape more precisely than round 7 did: I re-verified `gh repo delete` and GitHub's own web UI. **GitHub's web UI requires typing the actual, real repository name** to confirm deletion ("To verify that you're deleting the correct repository, type the name of the repository you want to delete") — a **per-target identity check**. `gh repo delete`'s own `--yes` flag is likewise ignored unless the caller passes the specific `owner/repo` argument explicitly. **Round 7 cited this precedent as if it validated a fixed generic literal (`UNINSTALL`) — it doesn't:** a fixed phrase provides no identity-verification property at all, and identity verification (confirming you're deleting *this* repo, not some other one) is the actual thing that precedent demonstrates. **Resolved honestly:** `crucible-hub`'s critical gate is a **deliberately simpler variant** than `gh repo delete`'s, and that's justified here for a reason specific to this tool — "the framework installation at `~/.claude`" is a **singleton target**, not one of many similarly-named resources where confirming the *wrong* one is the failure mode being guarded against. There is no second `~/.claude` to mistake this one for, so a fixed confirming phrase is adequate friction against an accidental or hasty confirmation — a different risk than the wrong-target risk `gh repo delete`/GitHub's typed-name gate defends against. From here on, `gh repo delete` is cited only for the narrower, genuinely-shared shape — **"require an explicit argument value, not a bare boolean flag, for a destructive default-adjacent action"** — not as validation of the specific literal chosen.

**Non-TTY, unchanged from round 6 in every other respect:** the dry-run preview still prints fully itemized before any confirmation; `--details` only affects the interactive Result screen's shape; the multiple-backups case still has no valid non-interactive default absent an explicit `--restore-backup=<timestamp>` flag (or explicit "restore none") — unresolved by design, exactly as round 6 left it (see Open Questions).

**Error state (foreign-file guard):** unchanged in mechanism from round 6, reworded to drop flags: `✗ 1 item skipped (foreign file at target, not framework-owned) — left untouched. Move or remove that file, then retry. See "List".`

---

### List

```
Components — 33 discovered                                  (b: back · q: quit)
                                                              (?: help)     [dim]

  Core: installed ✓ (framework prerequisite; shared foundation skills, standards & operational agents every tool depends on)

  STATUS      NAME                    KIND
  DIVERGED    shell-reviewer          agent   (source changed since install)
  installed   kotlin-developer        agent
  installed   build-core              skill   (framework dependency, not counted below)
  available   python-developer        agent
  available   standard-python         skill
  ... (28 more rows, one line each in the real output)

  12 installed · 2 diverged · 19 available · 33 discovered
  ! 2 items DIVERGED — run "Install" and select them to re-sync.
```

*(Table rows include both discovered optional units and any conditional-shared item already pulled in as a dependency — unchanged from round 6. "33 discovered" replaces round 6's "33 total" language, per the Dynamic discovery subsection above — the same number, framed as a scan result rather than a fixed fact. Round 8, Finding 4: `build-core`'s row is now annotated `(framework dependency, not counted below)` — it appears in this table because it's a real dependency on disk, but it is excluded from the `12 installed · 2 diverged · 19 available · 33 discovered` footer tally beneath the table, exactly like Install-all's own "Framework dependencies... not part of New/Replace/Skip" block. Round 9, Finding 5: this table shows only 5 of the 33 discovered rows with no elision marker, unlike Install-all/Uninstall-all's own bulk previews — a one-line "... (28 more rows...)" note is added above the footer tally, matching that same convention.)*

**States:** unchanged from round 6 in substance (*First-run*, *Fully installed*, *Diverged*, *Error*) — reworded per the no-flags rule and the full/abbreviated gloss split (List keeps the full Core gloss unconditionally, per Finding 10).

**Non-TTY / accessibility fallback:** unchanged from round 6 — plain space-aligned columns, no color, no box-drawing; `--format=env`/`--format=json` remain the machine-readable siblings.

---

### Accounts

```
Accounts                                                     (b: back · q: quit)
                                                              (?: help)     [dim]

  GitHub   ✓ authenticated as octocat (github.com)
  Jira     not authenticated

  1) Switch GitHub account
  2) Re-authenticate GitHub
  3) Configure Jira
  4) Re-authenticate Jira

  Select [1-4]:
```

*(Round 6's numbered `5) Back` item is retired — see Navigation & help above. "Jira: not authenticated" is plain, uncolored, no glyph.)*

**States:** unchanged from round 6 in substance. *Error (underlying tool missing, e.g. `gh` not installed):* `GitHub   gh not installed — install it, then re-run "Doctor"`.

**Non-TTY:** unchanged from round 6 — every menu action has an exact flag-driven equivalent (see Agent-facing mode below); no capability gap.

---

### Doctor

```
crucible-hub doctor — ~/.claude                              (b: back · q: quit)
                                                              (?: help)     [dim]

  Core: installed ✓ (framework prerequisite; shared foundation skills, standards & operational agents every tool depends on)

  Install state
    installed:   12/33 discovered
    diverged:    2

  Required tools
    git    ok
    gh     ok
    jq     ok
    curl   ok
    gpg    missing   (ssh-keygen ok — satisfies signing requirement, non-blocking)

  Accounts
    GitHub  ✓ authenticated as octocat (github.com)
    Jira    not authenticated

  Summary: 3 problems
    - gpg missing (ssh-keygen present, so signing still works)
    - Jira not authenticated
    - 2 items DIVERGED (kotlin-reviewer, shell-reviewer)

  Suggested next steps (3):
    1) Accounts → configure Jira
    2) Install → choose: kotlin-reviewer, shell-reviewer, to re-sync (or run "Install all")
    3) (optional) install gpg — ssh-keygen already satisfies the signing requirement, so this is non-blocking
       macOS: brew install gpg   ·   Linux: use your package manager (e.g. apt install gnupg)
```

*(Round 8, Finding 11: the `(b: back · q: quit · ?: help)` hint is now shown here — round 7's entire Doctor mockup omitted it. Round 8, Finding 12: step 2's wording is mechanism-explicit rather than the ambiguous "select." Round 9, Finding 7: step 2's wording is updated again from "filter to and toggle" to the mode-neutral "choose" — see the "No flags in the interactive UI" section above for the full reasoning.)*

**Required-tools remediation is genuinely actionable here** (resolves the tool-check half of Part A requirement 3), reworded to drop hub-flag syntax while keeping third-party remediation commands (`brew install gh`, a Linux install pointer) exactly as-is — those are not this hub's own flags:

```
    gh     missing   — required for GitHub account management
                        macOS:  brew install gh
                        Linux:  see https://github.com/cli/cli#installation
```

**States:** unchanged from round 6 in every substantive respect (*First-run* with its Sub-case A/B split, *Fully healthy*, *Degraded*) — every "Suggested next steps"/"Recommended:" line reworded per the no-flags rule and the mechanism-explicit wording above.

**Non-TTY:** unchanged from round 6 — `doctor --format=env`/`--format=json`, including `HUB_CORE_INSTALLED`/`core_installed`.

---

### Agent-facing mode

**Everything in this section is exactly where flag syntax belongs — nothing here changes in capability from round 6.** Unchanged examples (install/uninstall with `--components`, `--format=json`, blocked-dependents `HUB_BLOCKED_*`, status `--format=env`/`--format=json`, Install-all/Uninstall-all flag forms, `HUB_ACTED_ON_COUNT`/`HUB_INSTALLED_COUNT` naming rule) carry forward from round 6 verbatim in substance.

**A dry-run-without-`--apply` example, made explicit:**

```
$ crucible-hub install --components python-developer,react-developer
(prints the identical preview shown interactively above)
Nothing changed. Re-run with --apply to install.
$ echo $?
0
```

**The critical-uninstall confirmation flag, worked in full (round 8 — relocated here from the Uninstall-all section; see Finding 5: every other flow's non-interactive form already lives here, never inline in the interactive-flow prose, and this was the one place that convention was broken):**

```
$ crucible-hub uninstall --all --apply --non-interactive
HUB_STATUS=blocked
HUB_BLOCKED_REASON=confirmation_required
HUB_MESSAGE=critical action requires --confirm=UNINSTALL
(non-zero exit; nothing changed)

$ crucible-hub uninstall --all --apply --confirm=UNINSTALL --non-interactive
HUB_ACTION=uninstall
HUB_REQUESTED_ITEMS=all
HUB_CORE_REMOVED=true
HUB_ACTED_ON_COUNT=44
HUB_STATUS=ok
```

`--format=json` sibling for the blocked case: `{"status":"blocked","blocked_reason":"confirmation_required","message":"critical action requires --confirm=UNINSTALL"}` — **round 8, Finding 6:** this reuses the exact `status`/`blocked_reason` field shape `HUB_STATUS`/`HUB_BLOCKED_REASON` already use for the structurally identical blocking-dependents case (`HUB_BLOCKED_REASON=dependents_present`). Round 7 had instead invented a one-off `HUB_STATUS=error` / `HUB_ERROR=confirmation_required` shape for this one case — a third status value and a differently-shaped field that didn't match the established pattern for "operation halted, needs more input." Round 8 retires both in favor of the established shape.

**Round 9, Finding 3 — the closed vocabulary, stated explicitly for the first time:** `HUB_STATUS` has exactly **two** valid values anywhere in this document — `ok` (the action completed) and `blocked` (the action halted pending more input, never silently guessing); verified against every occurrence in this spec, no third value (including round 7's retired `error`) exists or is needed. `HUB_BLOCKED_REASON` had exactly **two** valid values at round 9 — `dependents_present` (the blocking-dependents case above) and `confirmation_required` (this critical-gate case). **Post-approval implementation update:** a genuine third `HUB_BLOCKED_REASON` value, `dependency_unresolved`, was added during implementation for `install`'s non-interactive dependency-resolution-failure path (an auto-pulled dependency name that can't be located in `--source` — see the Selective install section's "Error (dependency graph broken)" state) — added here explicitly, per this very rule, rather than invented ad hoc at the point of use. `HUB_BLOCKED_REASON` is now `{dependents_present, confirmation_required, dependency_unresolved}`. A future round introducing a further value for either field must likewise add it here explicitly.

**Post-approval implementation update (domain model) — two further `HUB_BLOCKED_REASON` values, added here explicitly per the rule above rather than left implicit in code:**

- **`selection_required`** — `install` was given a domain that has a mandatory **sub-selection** (Software Development's technologies, Project Management's backends) and no matching selection flag. Never guessed: installing "some default technology" because the caller did not say is exactly the silent assumption the never-guess discipline forbids. Emitted by `hub-install.sh`.
- **`restore_selection_required`** — `uninstall --all` found **more than one** `CLAUDE.md.backup.*` and no `--restore-backup` was given. Never guessed: silently picking "the newest" would overwrite the operating contract with a file the caller never named. Emitted by `hub-uninstall.sh`. Structurally the same shape as `selection_required` — "the caller must name which one" — hence the parallel spelling.

**These two spellings are normative and identical everywhere** — in this document, in the domain-screens addendum, and in the code that emits them. The domain-screens addendum describes the same first case in prose as a domain's "sub-selection", which invited a `subselection_required` variant; that variant is **rejected**, and `selection_required` (the spelling the code emits and this closed set publishes) is the single canonical value. `HUB_BLOCKED_REASON` is therefore `{dependents_present, confirmation_required, dependency_unresolved, selection_required, restore_selection_required}`.

**[RESEARCH, corrected for round 8 — see Finding 14 above for the full reasoning]:** `crucible-hub`'s `--confirm=UNINSTALL` is cited against `gh repo delete`/GitHub's typed-name precedent only for the narrower shape both share — an explicit argument value required for a destructive action, not a bare boolean flag — not as validation of the fixed literal itself, which this spec justifies independently (singleton target, no wrong-target risk to guard against).

**Non-TTY / CI behavior:** unchanged from round 6.

## Constraints

- **Color is decoration, never the sole signal.** Unchanged from round 6 — `NO_COLOR` and `--no-color` disable ANSI color entirely, per the NO_COLOR standard (no-color.org).
- **Non-TTY detection gates interactivity, not just styling.** Unchanged from round 6.
- **Spinners/animated progress are TTY- and CI-gated, and a fast local discovery scan at this bounded scale (~33–44 items) is expected to render instantly (sub-100ms), matching Nielsen's response-time research and `fzf`/`ripgrep` precedent (round 8, Finding 16 — this is now a measured expectation, not an absolute "never").** If a scan+diff genuinely exceeds roughly 1 second in practice (a much larger framework instance, a slower or network-mounted filesystem), the screen may show a minimal `Checking...` line rather than freeze silently — this UI-only spec states a performance *expectation*, it can't guarantee one. A visible indicator otherwise stays reserved for genuinely long operations (dependency resolution, install/uninstall writes), applied consistently.
- **Machine-readable output has two first-class siblings: `--format=env` and `--format=json`/`--json`.** Unchanged from round 6.
- **A `--accessible` mode is a first-class, opt-in fallback.** Unchanged from round 6.
- **Terminal width: assume a minimum of 80 columns.** The Main menu's status block is vertical, labeled lines by construction (Part A requirement 1), so there is nothing to soft-wrap around there. The 80-column floor still governs every other screen's reflow. **(Round 9, Finding 2: every mockup header carrying an inline nav hint was re-measured against this floor; every violation found is now wrapped onto its own line(s), matching List/Doctor/Accounts' pre-existing pattern.)**
- **No flags in the interactive UI — a hard wall over a precisely bounded scope (Part A requirement 2; see the Interaction contract subsection above for the full statement, its exact scope, and every reworded mockup).** Every interactive prompt, menu, confirmation, Result screen, and Doctor suggestion is flag-free; the flag-form equivalent is unchanged and lives exclusively in Agent-facing mode. **This wall does NOT extend to the "Non-TTY" prose callouts throughout this document (round 8, Finding 5; every such callout is now literally headed "Non-TTY" — round 9, Finding 4) — those describe the separate non-interactive path in prose, not as an on-screen UI element, and legitimately reference flag tokens where that's the only accurate way to describe that path.**
- **Navigation is global and consistent, with two named exceptions (round 8, Findings 8, 9, 17; exception (a) broadened in round 9, Finding 6): `q` quits the hub from anywhere, except (a) it asks once before discarding a non-empty pending selection — spanning both the checklist screen and the confirm/dry-run screen that follows it, not the checklist alone — and (b) it's a literal character, not a navigation key, inside the one free-text confirmation field; `b`/`back` goes back exactly one level; the help screen closes on ANY key, including `q`, rather than quitting** (see Navigation & help above for the full statement and the research behind each rule).
- **The Core gloss is full-length during genuine first-run and on List/Doctor always; abbreviated on the Main menu only once core is already installed (round 8, Finding 10 — this reverses round 7's "abbreviate everywhere on the Main menu" call).**
- **Confirmation-tier table — every mutating flow, mapped explicitly, with a named rationale:**

  | Flow | Tier | Prompt | Default | Color | Why |
  |---|---|---|---|---|---|
  | Selective install | Safe | `Proceed? [Y/n]:` | Yes | cyan | Purely additive; trivially reversible via the printed inverse "Uninstall" invocation. |
  | Install all | Safe | `Proceed? [Y/n]:` | Yes | cyan | Still purely additive and reversible via the printed inverse "Uninstall all" — but kept behind its full itemized dry-run preview so consent stays fully informed even at default-Yes. |
  | Selective uninstall | Dangerous | `Proceed? [y/N]:` | No | yellow | Removal carries real risk: the dependents-block/cascade mechanism, the foreign-file guard. |
  | Uninstall all | Critical | Type `UNINSTALL` to confirm (3 attempts, then auto-cancel — citing `sudo`'s own default `passwd_tries=3`, round 8 Finding 18) | none | red `WARNING:` | Removes core, the framework's own foundation; the multiple-backups edge case means the exact prior state isn't always deterministically restorable — now also stated on-screen (Finding 7). |

  This ladder is grounded in round 6's own existing reversibility framing (every mutating action already prints its own exact inverse invocation).
- **The typed-phrase critical gate supplements the dry-run preview; it never replaces it.** Uninstall-all's full itemized `Remove:`/`Framework dependencies:` preview prints in full exactly as round 6 specified; only the final confirm step is upgraded to the typed phrase. Its non-interactive equivalent is an explicit `--confirm=UNINSTALL` flag (spelling open, per the flag-spelling Open Question) alongside `--apply --non-interactive` — absent, the command fails loud with `HUB_STATUS=blocked` / `HUB_BLOCKED_REASON=confirmation_required` (round 8, Finding 6), matching this spec's existing "never guess" discipline for `--cascade`/`--restore-backup`. **`HUB_STATUS`/`HUB_BLOCKED_REASON` are each a closed, two-value set — see Agent-facing mode above (round 9, Finding 3).** **Human/agent parity, a first-class named invariant, explicitly covers this gate — zero capability gap.**
- **Core-tier and conditional-shared-tier membership are curated, not discoverable — see the architecture note in the shared vocabulary above.** Discovery auto-derives optional-tier membership from naming pattern only; the exact storage mechanism for the other two tiers' classification is explicitly deferred to the implementation spec.
- **Every specific count in this document is one internally-consistent worked example of dynamic discovery, never a hardcoded constant — see the "illustrative worked example" Constraint above.** The invariants that must hold on any real system are now **two formulas, not one** (round 8, Finding 1): `New + Replace + Skip = discovered-optional-count` always; `(New + Replace) + conditional-shared-pulled-in + core = total-acted-on-count` for install-type flows (Skip excluded); `discovered-optional-count + conditional-shared-count + core = total-acted-on-count` for full-removal (nothing excluded).
- **Glyph legend is complete and every glyph is drawn at least once — see the Glyph & color legend subsection above** for the full table, the ASCII-fallback additions, and why `*` was dropped.
- **"Not authenticated" is neutral everywhere outside Doctor's aggregate Summary — see the Glyph & color legend subsection above.**
- **Consistency across every mode:** one shared status vocabulary, one dry-run-then-confirm pattern for every mutating action (tiered — see the confirmation-tier table above), vertical status display everywhere a status view exists (Part A requirement 1).
- **Human/agent parity is a first-class, named invariant.** No interactive action, including the typed-phrase gate, lacks a flag-driven equivalent.
- **Dependency resolution is one shared capability, not two.** Unchanged from round 6.
- **The foreign-file-at-target write guard is universal.** Unchanged from round 6.
- **The status-summary computation is one shared computation, rendered at three call sites, and the conditional-shared tier's count is always excluded from it (round 8: now applied consistently at every call site, including Selective install's own preview — see Finding 1/3; round 9 completes this by correcting the actual auto-pulled count shown there).**
- **Core is implicit, exempt, and separately tracked — never a selectable target.** Unchanged from round 6.
- **The DRY-RUN preview always itemizes every item by name; the post-apply Result screen still summarizes the durable end-state by default, itemizing as an opt-in — matching terraform's own convention.** Unchanged from round 6 in mechanism. **Naming, unchanged:** the detail toggle is `--details`, not `--verbose` (clig.dev flags `--verbose`/`-v` as industry-reserved and ambiguous). **Wording:** the interactive follow-up prompt reuses round 6's own "Show details? [y/N]" phrasing throughout this document.
- **Back/cancel is unified into one global nav-hint model — see Navigation & help above** for the full statement, including the two named exceptions (typed-phrase field, help screen).
- **Every empty/first-run state names a next action.** Unchanged from round 6, reworded per the no-flags rule.
- **Every reversal/remediation line uses the mode-neutral verb `choose`, never the ambiguous "select" or the checklist-only "filter to and toggle" (round 8, Finding 12; refined in round 9, Finding 7 — "filter to and toggle" accurately named only the checklist's own mechanism, not accessible mode's typed-selection mechanism; "choose" now covers both, with a one-time note at first use in the "No flags in the interactive UI" section above).**

## Open questions

- Exact command/binary name and install location (`crucible-hub` is illustrative only).
- Exact flag spellings — deferred to the implementation spec, including the critical-uninstall confirmation flag's precise spelling (illustrated here as `--confirm=UNINSTALL`). **Not deferred:** that `--format=env`, `--format=json`/`--json`, `--accessible`, `--details`/`-q`, and the critical-confirmation flag all exist as named, first-class options — only their precise spelling is left open.
- Non-interactive default when multiple `CLAUDE.md` backups exist and no `--restore-backup=<timestamp>` flag is given: fail loud, or default to most-recent with a warning? Unchanged from round 6 — deliberately left open.
- Whether `--accessible` mode is ever auto-detected — unchanged from round 6, treated as opt-in only.
- Visual theme specifics (exact hex values, box-drawing character set, TUI framework choice) — explicitly deferred, per this document's non-goals. The four semantic hues (blue/red/green/yellow) are the one exception, now in-scope (see the Non-goals section above).
- Whether "traceability" implies anything beyond the itemized per-action Result screen specified here (e.g. a persistent, queryable multi-run history/log) — unchanged from round 6, still open.
- The exact enumerated core set AND the exact enumerated conditional-shared tier reflect the framework's real structure as confirmed at spec time — unchanged from round 6's open question about keeping both in sync as the framework evolves, extended to note that neither tier's membership is naming-pattern-derivable, so whatever sync mechanism the implementation spec chooses must be an explicit registry/tag, not an inference rule.
- Whether the bulk DRY-RUN preview's one-item-per-line itemization should eventually be grouped/columnar for better scannability at full scale — unchanged from round 6, still open.
- ~~Whether the Core gloss should be abbreviated on the Main menu~~ — RESOLVED (round 7 first attempted this, round 8 corrected the resolution — see Finding 10 and the Main menu section above for the final first-run/steady-state split).

---

**Sources cited for this round's research (round 8 — corrections/additions to round 7's list; round 6's carried-forward NO_COLOR citation still applies; round 9 introduces no new research and adds no new citations):**
- [q key convention in less/man/top-family pager and monitor tools](https://dev.to/konyu/how-to-terminate-vim-vi-5gn2) and general pager-convention discussion. *(unchanged from round 7)*
- [lazygit's global `?` help-key convention](https://www.commandinline.com/lazygit-tutorial-master-git/), confirmed current. *(unchanged from round 7)*
- [Docker's daemon-connection error surfaces only at the point a command needs it, never at CLI startup](https://www.baeldung.com/ops/docker-cannot-connect) — grounding the lazy-check-over-blocking-gate decision. *(unchanged from round 7; this decision no longer also cites clig.dev — see next entry)*
- **[Round 8, Finding 13]** [clig.dev](https://clig.dev/) — re-checked directly for round 8; contains general composability guidance ("your only choice is over whether it will be a well-behaved part [of a larger system]") but **no line that directly addresses lazy-vs-blocking dependency checks**. Round 7 attributed a supporting "philosophy" to clig.dev here without a quotable line behind it; round 8 drops that attribution for this specific decision rather than continue citing it uncritically.
- **[Round 8, Finding 14]** [GitHub's web UI repository-deletion flow requires typing the actual repository name to confirm](https://docs.github.com/en/repositories/creating-and-managing-repositories/deleting-a-repository) ("To verify that you're deleting the correct repository, type the name of the repository you want to delete") — the genuine precedent for **per-target identity verification**, which `crucible-hub`'s fixed literal does *not* provide; cited now only for the narrower shared shape (explicit-argument-required, not a bare boolean), per the corrected reasoning above.
- **[Round 8, Finding 14]** [`gh repo delete`'s `--yes` is ignored without an explicit `owner/repo` argument](https://github.com/cli/cli/issues/12033) — corroborating the same "explicit argument, not a bare flag" shape from the CLI side.
- [`gh repo delete --confirm` naming discussion](https://github.com/cli/cli/issues/6892) — retained from round 7 as background on the flag's own naming history; not cited as validating the fixed-literal design (see Finding 14's corrected reasoning above).
- [Terraform's green-create/yellow-change/red-destroy plan/apply color convention](https://github.com/hashicorp/terraform/issues/15350) — **[Round 8, Finding 15]** re-verified: Terraform uses green for "will create" with no separate preview-vs-result color, which does not support (and, read carefully, undermines) the "preview-vs-result distinction" argument round 7 offered for diverging from it. Cited now only to state, accurately, what convention this spec's `+` color deliberately diverges from by explicit human choice.
- **[Round 8, Finding 15]** [Pulumi's own green `+` for create, used identically in `preview` and `up`](https://www.pulumi.com/docs/iac/cli/commands/pulumi_preview/) — same finding as Terraform above: green throughout, no distinct preview color, so neither precedent backs blue.
- [Blue-as-informational vs. green-as-success as an independently attested terminal color convention](https://defencedev.com/linux-tutorial-basic/terminal-colors-bash-ansi-guide/) — the one genuinely independent rationale for blue-for-`+`, offered on its own merits (round 8: no longer alongside a false claim of Terraform/Pulumi support).
- [Nielsen Norman Group's 0.1s/1s/10s response-time thresholds](https://www.nngroup.com/articles/response-times-3-important-limits/), confirmed current — grounding the scanning-indicator threshold (round 8, Finding 16: now a measured threshold, not an absolute).
- [kubectl's own dry-run-then-explicit-confirm precedent for bulk/irreversible deletion](https://github.com/kubernetes/enhancements/blob/master/keps/sig-cli/3895-kubectl-delete-interactivity/README.md) — corroborating that preview-then-confirm is the established shape for this class of action. *(unchanged from round 7)*
- **[Round 8, Finding 18]** [`sudo`'s `passwd_tries` option, defaulting to 3 attempts before giving up](https://linux.die.net/man/5/sudoers) — replacing round 7's unresearched "reference daemon" citation for the critical gate's 3-attempt retry limit; a real, verifiable, widely-known precedent for a small retry count on a security/destructive-confirmation gate.
- **[Round 8, Finding 17]** vim's `:help` buffer convention (`q` closes the help window rather than quitting vim) — general, well-known editor convention grounding the help-screen's exception to the global `q`-quits rule; not tied to a single citable URL, cited here as an editor-behavior precedent rather than a specific document.
