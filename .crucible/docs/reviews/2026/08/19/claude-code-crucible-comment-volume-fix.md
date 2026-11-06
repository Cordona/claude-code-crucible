# Review: claude-code-crucible

**Repo:** claude-code-crucible
**Started:** 2026-08-19 · **Last updated:** 2026-08-19
**Round:** 5 (of 3 max)
**Verdict:** APPROVED

## Round history
- Round 1: lens-consistency-reviewer, lens-compatibility-reviewer
- Round 2: lens-consistency-reviewer, lens-compatibility-reviewer
- Round 3: lens-consistency-reviewer
- Round 4: lens-consistency-reviewer
- Round 5: lens-consistency-reviewer, lens-compatibility-reviewer

## Findings

### CONS-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/agents/reviewers/lens/lens-clean-code-reviewer.md:91

The lens's step 6 asserted its own numeric judgment bars (2+ units, 2+ places) instead of citing standard-clean-code, which owns WHAT-good-looks-like including numeric bars.
→ Fix: Moved both bars into standard-clean-code's proportionality paragraph as two named failure shapes (Volume/Placement); the lens now cites them by name instead of restating the numbers.

### CONS-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/shared/build-core/SKILL.md:51

build-core promised a developer's deferred-to-commit rationale would reach the git-operator commit brief, but no receiving contract was amended to carry it.
→ Fix: Named the routing explicitly in build-report-standards' Key decisions row and in flow-git-operations G2's brief list.

### CONS-003 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-review/SKILL.md:110

The cross-artifact duplication signal's sole input (commit message/PR-MR description) had no producer anywhere in flow-review's dispatch path.
→ Fix: Added the commit message/PR-MR description as an optional dispatch input in flow-review section 5a, scoped to when it actually exists.

### CONS-004 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/agents/reviewers/lens/lens-clean-code-reviewer.md:23

New prompt-input item 6 broke the re-review-item-always-last convention held by all sibling reviewer bodies, and falsely declared itself optional under a MUST-include preamble.
→ Fix: Split into a proper standalone item for the commit message/PR description, with the re-review item restored to last position.

### CONS-005 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/agents/reviewers/lens/lens-clean-code-reviewer.md:96

The Category Vocabulary section carried follow-on explanatory prose, against the 16/16 bare-list precedent across sibling reviewer bodies.
→ Fix: Deleted the paragraph; the disambiguation it stated remains in step 6 and the Edge Cases table.

### CONS-006 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/agents/reviewers/lens/lens-clean-code-reviewer.md:134

The rewrite-requirement Constraints bullet grew to a three-clause paragraph, unlike its single-clause siblings.
→ Fix: Reduced to one prohibition plus a short scope pointer, matching sibling bullet shape.

### CONS-007 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/shared/build-core/SKILL.md:51

build-core cited a report field as 'Key Decisions' with no pointer to its owning skill, unlike the adjacent Validation-field precedent.
→ Fix: Reworded to cite the field by canonical name plus owner on first mention.

### CONS-008 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/agents/reviewers/lens/lens-clean-code-reviewer.md:23

The round-2 fix folded the commit-message input into the re-review item, creating a label mismatch and a non-standard shape versus sibling precedent.
→ Fix: Split back into two separate items matching rust-reviewer.md's exact precedent shape.

### CONS-009 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-review/SKILL.md:110

The new dispatch-list item was appended after the 'prior-round findings...so IDs stay stable' terminator, unlike sibling flows' convention of ending with that exact clause.
→ Fix: Reordered so the terminator clause stays last, matching flow-implementation and flow-testing.

### CONS-010 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/agents/specialists/git-operator/git-operator.md:17

flow-git-operations G2 relayed a deferred-to-commit rationale to git-operator, but git-operator's own declared prompt-input list never mirrored it, and nothing told the operator what to do with it.
→ Fix: Added the mirrored input item to git-operator's prompt-input list and a handling instruction under its Message-authoring judgment call.

### CONS-011 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/flows/flow-git-operations/SKILL.md:239

The deferred-to-commit-rationale relay was added only to the commit path (G2) and the Pull-Request Path; a GitLab MR-only operation (commits already landed) had no destination for it, and the Merge-Request Path does not inherit the Pull-Request Path's list (it fully restates its own).
→ Fix: Added the identical relay clause directly to the Merge-Request Path's own step 1; corrected a prior footer claim that had incorrectly asserted inheritance.

### CONS-012 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/shared/build-report-standards/SKILL.md:28

After a PR/MR destination was added alongside the commit destination for the deferred rationale, three upstream sites describing its routing still named only the commit destination.
→ Fix: Widened all three sites to name both destinations, whichever still exists.
