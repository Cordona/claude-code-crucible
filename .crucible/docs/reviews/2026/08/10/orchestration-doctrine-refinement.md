# Review: claude-code-crucible

**Repo:** claude-code-crucible
**Started:** 2026-08-10 · **Last updated:** 2026-08-10
**Round:** 4 (of 3 max)
**Verdict:** APPROVED

## Round history
- Round 1: lens-security-reviewer, lens-compatibility-reviewer, lens-consistency-reviewer, lens-clean-code-reviewer
- Round 2: lens-security-reviewer, lens-compatibility-reviewer, lens-consistency-reviewer, lens-clean-code-reviewer
- Round 3: lens-security-reviewer, lens-compatibility-reviewer, lens-consistency-reviewer, lens-clean-code-reviewer
- Round 4: lens-security-reviewer, lens-compatibility-reviewer

## Findings

### SEC-001 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:51

flow-testing's gate-skip exception rested on one unverifiable self-asserted precondition with no default-deny
→ Fix: replaced with four enumerated conjunctive preconditions plus an explicit fail-closed default

### SEC-002 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:77-88

flow-implementation's §3 plan never disclosed the mid-flow flow-testing dispatch it was claimed to pre-authorize
→ Fix: §3 plan template now names the seats and loop for the mid-flow flow-testing dispatch

### SEC-003 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:110

interim reports could read as build-done while the {tech}-reviewer pass was still outstanding
→ Fix: mandatory verbatim outstanding-reviewer statement at every interim checkpoint

### SEC-004 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:110

the live-validation confirmation could be self-supplied by the orchestrator instead of the human
→ Fix: confirmation must now be the human's own explicit in-turn statement; a probe only gathers evidence

### SEC-005 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-review/SKILL.md:52

flow-review asserted the {tech}-reviewer already ran unconditionally, false for an open Validate-First deferral
→ Fix: made the not-re-seated rule explicitly conditional on the deferred pass having closed

### SEC-006 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:114

no durable marker for the outstanding deferred-reviewer obligation across the flow-testing dispatch
→ Fix: added carried-obligation invariants restating the outstanding reviewer at every subsequent report, plus a fail-closed terminal check in flow-git-operations

### SEC-007 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:110

the live-validation iteration loop was unbounded, unlike every other loop in the framework
→ Fix: capped at 3 rounds of iteration before re-presenting the gate

### SEC-008 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:36

the live-testability judgment had no fail-closed default; a weak check could qualify a task for deferral
→ Fix: added on any doubt, recommend Pair-First with named weak-check examples

### SEC-009 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:6

stale tests-are-last text reinforced the premature-done misread SEC-003 depends on
→ Fix: retitled H1 and rationale to reflect confirmation-gated, not chronologically-last, tests

### COMPAT-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** software-development/shared/review-core/SKILL.md:20

review-core cited flow-implementation's old §4c for the diff-artifact rule after renumbering
→ Fix: repointed citation to §4d

### COMPAT-007 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** software-development/flows/flow-git-operations/SKILL.md:44-53

the commit gate's Reviewed precondition equated touched-flow-implementation with reviewer-ran, false in Validate-First's new window
→ Fix: G1.2 now requires the {tech}-reviewer pass to have actually closed, independent of other scrutiny received

### COMPAT-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** CLAUDE.md:79

an invariant called both floors the fixed un-derived roster of their flow, contradicting the file's own softened roster claim
→ Fix: reworded to fixed seats, not fixed WHEN those seats run

### COMPAT-005 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** CLAUDE.md:66

the unqualified never-dispatch-without-approval invariant didn't reference the new gate-skip exception stated elsewhere
→ Fix: added the carve-out reference pointing at flow-testing's documented exception

### COMPAT-004 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:51

the gate-skip exception claimed the Validate-First plan names flow-testing as the next step, but the plan template didn't list it
→ Fix: flow-implementation §3's template now carries the seats and loop line for this dispatch

### COMPAT-008 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:143

flow-testing's exit summary and invariants carried no hand-back-to-flow-implementation reminder for the case-3 path
→ Fix: added a mandatory disclosure plus a matching invariant

### COMPAT-006 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** README.md:213-223

README's how-a-request-flows still described unconditional dev-reviewer and tests-always-last
→ Fix: rewrote steps 2 and 4 to describe both paths

### COMPAT-003 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:47

§3 heading still read MANDATORY before ANY dispatch directly above a documented exception
→ Fix: softened heading to MANDATORY, one documented exception

### CONS-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/shared/review-core/SKILL.md:20

same stale §4c citation independently found by the compatibility lens
→ Fix: repointed to §4d

### CONS-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:48

Shape as a proper noun collided with shape already used generically throughout the framework's prose
→ Fix: renamed to Validate-First/Pair-First throughout

### CONS-003 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:6

flow-testing's H1 and last rationale contradicted its own new §0 trigger 3
→ Fix: retitled both

### CONS-004 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** README.md:241

README's Entry Modes mirror and flow prose weren't updated to match CLAUDE.md's new doctrine
→ Fix: updated the mirror row and flow steps

### CONS-005 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:174

opaque letter labels were a new fourth naming pattern alongside this framework's descriptive-name conventions
→ Fix: renamed to descriptive hyphenated Title-Case names matching the repo's existing pattern

### CONS-006 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:77

new gate-plan bullets used pipe for placeholder alternatives where every other template in the repo uses slash
→ Fix: changed to slash

### CONS-007 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/shared/review-core/SKILL.md:40

review-core's zero-tests default assumption needed a Validate-First carve-out since that path's correctness pass now runs after flow-testing
→ Fix: added the explicit carve-out

### CONS-008 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** CLAUDE.md:31

CLAUDE.md's rewritten IMPLEMENT row abandoned the arrow-chained pipeline format every other row uses
→ Fix: restored the arrow-chain format

### CLEAN-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:40

the defers-WHEN-never-WHETHER rule was restated 3x per file in normative prose
→ Fix: reduced to one canonical normative site per file plus its expected invariant restatement

### CLEAN-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:50

Shape A/B needed an inline gloss at nearly every use, evidence of a weak name
→ Fix: renamed to self-describing Validate-First/Pair-First

### CLEAN-003 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:30

flow-testing claimed its roster was the same shape as flow-implementation §2, false once §2 became two paths
→ Fix: rewrote as a contrast rather than an inherited definition

### CLEAN-004 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** CLAUDE.md:56

diff-relative changelog phrasing (now/no-longer/rather-than) sat in normative prose with no footer for a reader to resolve now against
→ Fix: restated in present tense across CLAUDE.md/README/flow-testing

### CLEAN-005 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:20

the re-entry sentence restated one rule three times in one paragraph
→ Fix: trimmed to one rule plus its reason plus its consequence

### CLEAN-006 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:6

four headings asserted rules their own bodies revoked
→ Fix: retitled all four to match their bodies

### CLEAN-007 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-review/SKILL.md:23

flow-review's added note self-contradicted within one sentence pair and left an ordering case unhandled
→ Fix: replaced with a single firm rule covering the unhandled case

### CLEAN-008 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:106

the conditional detour was structurally one level too low relative to its dispatch-only siblings
→ Fix: named the detour in the section heading instead of silently absorbing it

### SEC-010 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** CONTINUATION.md:19-28

the agent-onboarding doc still stated the pre-change doctrine (reviewer always immediate, tests always last)
→ Fix: updated to name the Validate-First/Pair-First split and the new tests-can-precede-reviewer rule

### SEC-011 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:80

the pre-authorized flow-testing dispatch's seats/loop were disclosed but not its test scope
→ Fix: added a Test scope field to the §3 plan template for Validate-First

### SEC-012 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-git-operations/SKILL.md:44

tightening the Reviewed precondition to require a closed {tech}-reviewer pass made it unsatisfiable for framework-prose/DIRECT-mode changes, which have no reviewer at all
→ Fix: added the execution-test-floor branch as the alternate way to satisfy the precondition for that class of change

### COMPAT-009 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** CLAUDE.md:41

the commit-gate tightening in flow-git-operations didn't propagate to its two always-loaded mirrors, which still stated the looser precondition
→ Fix: reworded both mirrors to match the corrected precondition

### COMPAT-010 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** software-development/flows/flow-git-operations/SKILL.md:52

same underlying gap as SEC-012, found independently: the tightened absolute wording made precondition 2 unsatisfiable for the no-reviewer class of change
→ Fix: added the execution-test-floor branch

### CONS-009 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** CLAUDE.md:41

same stale gate-precondition mirrors independently found by the compatibility lens
→ Fix: reworded both to match the corrected owner

### CONS-010 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:48

§2 said the deferred reviewer joins later in §4c, but the reviewer actually joins at §4d
→ Fix: corrected the citation

### CONS-011 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:51

the new four-precondition block used bare §4a/§4b/§4c refs, which per this repo's own citation rule resolve to this file's own distinct §4a/§4b/§4c, not flow-implementation's
→ Fix: qualified all three references to explicitly name flow-implementation

### CONS-012 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:75

the Recommended-path gate bullet had no omission rule for the review-only/Direct variants, unlike its sibling Spec bullet
→ Fix: added the matching omission rule

### CLEAN-009 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-review/SKILL.md:48

§3's heading and invariant still stated the not-re-seated rule unconditionally even though the body was made conditional
→ Fix: carried the condition into both the heading and the invariant

### CLEAN-010 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-review/SKILL.md:23

the exception label was claimed by two different cases one section apart, §0 and §3
→ Fix: dropped §0's label, letting §3 own naming its own cases

### CLEAN-011 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** CLAUDE.md:66

one concept had three different vocabularies across three files, one of which negated another
→ Fix: standardized on gate is pre-satisfied everywhere the concept appears

### CLEAN-012 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-git-operations/SKILL.md:47

G1.2 embedded a bracketed editorial directive inside the quoted line the agent is meant to speak verbatim
→ Fix: split into two plain example phrasings instead of a nested bracketed insert

### CLEAN-013 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:213

version footers had become stacked, unbounded review changelogs citing unresolvable finding IDs
→ Fix: trimmed each footer to the current version's rationale plus a pointer to git history

### CLEAN-014 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** README.md:213-219

README never named the two paths, so a reader met Validate-First/Pair-First as undefined proper nouns elsewhere
→ Fix: named both paths and split the fork into sub-bullets

### SEC-013 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:38-46

the enriched live-testability signals gave quotable justification for Validate-First on security-sensitive code, where live validation only proves the happy path and can't catch an auth bypass or fail-open error
→ Fix: added an explicit standing case: auth/crypto/secrets/untrusted-input paths recommend Pair-First regardless of other signals

### SEC-014 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:206

flow-implementation's own Invariants block carried no bullet for the flow-testing-always-gates rule, unlike its two sibling files
→ Fix: added the matching invariant bullet

### COMPAT-011 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:222

the v1.4 footer omitted the §1 live-testability rewrite from its list of what changed
→ Fix: v1.5 footer now describes the §1 collapse and security carve-out explicitly

### COMPAT-012 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** .crucible/docs/reviews/2026/08/10/orchestration-doctrine-refinement.json

the persisted artifact's round-1/2 findings describe a gate-skip mechanism since deliberately removed, with no supersession marker, risking a future re-review reading the reversal as a regression
→ Fix: the supersession is recorded in the flow-implementation v1.5 and flow-testing v2.5 SKILL.md footers, which explicitly name the superseded findings and mechanism; the JSON schema has no free-text artifact-level note field to duplicate this in

### COMPAT-013 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:48

the name-the-source instruction sat after the Pair-First signals, reading as if it also applied to the no-live-source branch
→ Fix: split into per-branch instructions: name the source for Validate-First, state why not for Pair-First

### COMPAT-014 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** CLAUDE.md:56

a bare §3 citation for flow-testing's gate violated this file's own citation-qualification rule
→ Fix: qualified as flow-testing §3

### CONS-013 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:46

Pair-First's definition (no live source) didn't cover the new case where a live source exists but is destructive/slow/security-sensitive
→ Fix: widened the definition and the gate template's Pair-First branch to no usable live source

### CONS-014 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** CLAUDE.md:56

same bare §3 citation independently found by the compatibility lens
→ Fix: qualified as flow-testing §3

### CONS-015 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:122

two §3 tokens two clauses apart pointed at different documents (flow-testing's vs this file's own)
→ Fix: disambiguated both references explicitly by name

### CONS-016 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:47

the gate heading's added NO exceptions qualifier was inconsistent with every sibling gate heading in the repo, which name only the gated object
→ Fix: reverted heading to MANDATORY before ANY dispatch; the body and invariant already carry the no-exceptions force

### CONS-017 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:43

the negative signal list lacked the same illustrative-not-sufficient hedge the positive list had
→ Fix: resolved by collapsing the mirrored list into one hedged list plus a closing inverse sentence, per CLEAN-015

### CLEAN-015 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:43

the two mirrored bulleted signal lists read as a pro/con scorecard, the exact tally-reasoning the open-judgment framing was meant to prevent
→ Fix: collapsed to one list plus a single closing sentence covering the inverse and the security carve-out

### CLEAN-016 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:100

a same-section restatement ten lines from its source, and three consecutive sentences asserting one absolute in flow-testing §3
→ Fix: trimmed both to a single statement plus a pointer

### CLEAN-017 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** CLAUDE.md:79

the gate-always-fires rule was restated three times within one invariant bullet
→ Fix: trimmed to one classification sentence

### CLEAN-018 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-testing/SKILL.md:167

the version footer cited bare finding IDs unresolvable without knowing the artifact's path
→ Fix: replaced with a plain-language gloss, no bare IDs

### CLEAN-019 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/flows/flow-implementation/SKILL.md:222

the v1.4 footer's all now moot claim misdescribed the still-live test-scope field
→ Fix: v1.5 footer now names only the genuinely superseded item

### SEC-015 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** software-development/flows/flow-git-operations/SKILL.md:51

the commit gate's Reviewed precondition resolved once per whole diff, so a diff mixing reviewer-backed code with framework-prose changes could clear on the execution-test branch alone, leaving the code half never seen by a {tech}-reviewer
→ Fix: added a requirement that each class in a mixed diff clears its own mechanism independently, never one branch vouching for the whole diff

### COMPAT-015 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** CLAUDE.md:99

CLAUDE.md's roster summary still stated the retired strict biconditional (live source exists or not), omitting the security-sensitive carve-out and the usable-live-source widening flow-implementation v1.5 shipped
→ Fix: replaced the restated criterion with a pointer to flow-implementation §1 as the sole definition, per this file's own not-restating-owners convention

### COMPAT-016 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** README.md:215

same retired criterion in the human-facing docs
→ Fix: widened both to name the usable-source and security-sensitive disjuncts and flag the choice as open judgment
