# Review: claude-code-crucible

**Repo:** claude-code-crucible  
**Started:** 2026-10-03 · **Last updated:** 2026-10-03  
**Round:** 1  
**Verdict:** CHANGES_REQUIRED

## Round history
- Round 1: lens-consistency-reviewer, lens-self-documenting-code-reviewer, lens-compatibility-reviewer, lens-clean-code-reviewer, lens-security-reviewer

## Findings

### SEC-001 — HIGH
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/shared/review-core/SKILL.md  
**Trigger:** an overflow reachable only through a malformed length field is filed edge-case as 'rare input' and approved

Q3 treats rare input as unlikely, but attackers choose rare inputs, so exploitable defects leave the gate.  
→ Fix: Rarity never lowers a trigger an untrusted party can choose; such a path is realistic.

### SEC-002 — HIGH
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/shared/review-core/SKILL.md  
**Trigger:** a new shell sink downstream of an agent that reads PR comments is classed speculative as 'an agent in the loop'

Q2 conflates actors who control the system with actors who can influence its inputs.  
→ Fix: Out of model only an actor who already holds the access the attack would grant; influencers are in model; widening or newly relying on an untrusted feed counts.

### SEC-003 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-implementation/SKILL.md  
**Trigger:** a reviewer or a realism check labels an exploitable HIGH edge-case and the loop reaches APPROVED

Moving a CRITICAL/HIGH out of the gate needs no human consent, unlike ACK.  
→ Fix: Require a human decision for an edge-case or demoted CRITICAL/HIGH; show edge cases by severity.

### COMPAT-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-compatibility-reviewer  
**File:** software-development/flows/flow-git-operations/SKILL.md  
**Trigger:** an open edge-case HIGH meets the commit gate or the docs/tech-pair loop that still gate on any open CRITICAL/HIGH

Untouched flows still gate on any open CRITICAL/HIGH.  
→ Fix: Qualify each as realistic; decide tech-pair's fully-clean rule.

### CONS-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/flows/flow-implementation/SKILL.md  
**Trigger:** the orchestrator dispatches the arbiter on its own and a HIGH leaves the verdict without a human decision

An orchestrator-initiated ruling drops a CRITICAL/HIGH, a power reserved for the human.  
→ Fix: Make the ruling a recommendation the human decides.

### CONS-002 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/review-arbiter.md  
**Trigger:** every realism check dispatch picks the arbiter by a description scoped to external review

The arbiter description, prompt list and schema still scope it to flow-external-review.  
→ Fix: Advertise the realism check and its brief; mark external-review-only inputs.

### CONS-003 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/review-arbiter.md  
**Trigger:** an arbiter on a realism check looks for a rationale field

Names a rationale output the schema lacks.  
→ Fix: Say evidence.

### CONS-004 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/contracts/review-finding-report.schema.json  
**Trigger:** every reviewer shapes its first 1.2 report from the schema example

The worked example contradicts the domain's severity, vocabulary and ownership.  
→ Fix: Fix the example's grades, categories and reviewer.

### CONS-005 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/shared/review-core/SKILL.md  
**Trigger:** a maintainability finding must class a next-change trigger

Q3 makes any future change an edge case, contradicting MEDIUM's definition.  
→ Fix: The next ordinary edit to touched code is a realistic trigger.

### CONS-006 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/flows/flow-review/SKILL.md  
**Trigger:** the human elects an edge case and the orchestrator looks up how to record it

flow-review's script summary is stale and never names --realism.  
→ Fix: Update the script surface and name the elect command.

### CONS-007 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/shared/review-report-standards/SKILL.md  
**Trigger:** the orchestrator renders a report with edge cases

Item 3 grouping disagrees with the example.  
→ Fix: Align item 3 and the example.

### CONS-008 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/shared/review-report-standards/SKILL.md  
**Trigger:** a reader hits the new example lines

DTO and DB are not expanded.  
→ Fix: Expand or reword.

### CONS-009 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/flows/flow-review/scripts/review-create.sh  
**Trigger:** a caller passes an invalid realism to review-create.sh

The new exit-2 rejection skips usage.  
→ Fix: Print usage first.

### CLEAN-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/flows/flow-review/scripts/review-create.sh  
**Trigger:** the next change to the realism vocabulary must be made in two scripts

JQ_REALISM is duplicated; the lib the fixtures copy could hold it.  
→ Fix: Move it into review-aggregates.jq.

### CLEAN-002 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/contracts/review-artifact.schema.json  
**Trigger:** tightening one_line in one schema leaves the other accepting it

one_line is duplicated. Convergent with CONS-010.  
→ Fix: Extract a shared schema.

### DOC-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/contracts/review-finding-report.schema.json  
**Trigger:** the next change to the counting rule must be edited in about nine schema descriptions

The counting rule is restated in schema descriptions.  
→ Fix: Cite review-report-standards only.

### DOC-002 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/shared/review-core/SKILL.md  
**Trigger:** every reviewer reads the edge-case rule twice

review-core restates consequences review-report-standards owns.  
→ Fix: Trim review-core's table rows.

### DOC-003 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/shared/review-report-standards/SKILL.md  
**Trigger:** every reviewer load pays for orchestrator procedure

The election procedure is duplicated into a reviewer skill.  
→ Fix: Delete it there.

### DOC-004 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** CLAUDE.md  
**Trigger:** CLAUDE.md loads every session

The invariant restates the class consequences and cites the wrong owner.  
→ Fix: Shorten and cite both owners.

### DOC-005 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/agents/reviewers/lens/lens-security-reviewer.md  
**Trigger:** an edit to Q2 leaves the security lens copy stale

The lens paraphrases review-core Q2.  
→ Fix: Cite Q2; keep only lens-specific clauses.

### DOC-006 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/flows/flow-review/scripts/review-create.sh  
**Trigger:** an editor expects the check below the banner

A banner sits 75 lines from its check.  
→ Fix: Move it above the check.

### DOC-007 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/flows/flow-review/scripts/lib/review-aggregates.jq  
**Trigger:** a reader gets change history from comments

History narration in two comments.  
→ Fix: Rephrase as present-tense rules.

## Edge cases (not recommended to fix)

### SEC-004 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-review/scripts/render-md.sh  
**Trigger:** an unclosed details tag in a trigger collapses later sections in an HTML preview

Inline raw HTML still renders in the new text fields.  
→ Fix: Escape < and & in neutralize.

### CONS-010 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/contracts/review-finding-report.schema.json  
**Trigger:** a later edit tightens one-line in one schema only

one_line is duplicated in two schemas. Convergent with CLEAN-002.  
→ Fix: Extract a shared schema.

### CONS-011 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/contracts/review-arbiter-verdict.schema.json  
**Trigger:** a later rename of a realism value leaves the arbiter's inline enum stale

The arbiter's realism enum is inlined without explanation.  
→ Fix: Add a $comment or anyOf.

## Speculative (not filed)

- **software-development/flows/flow-review/scripts/review-update-status.sh** — the realism case arm is another copy of the value domain · needs: house convention hard-codes enums in case arms; no vocabulary change planned
- **software-development/contracts/review-finding-report.schema.json** — finding-realism.schema.json not yet deployed · needs: nothing resolves $ref mechanically; hub tops it up
- **software-development/shared/review-core/SKILL.md** — advocate seats might emit realism fields · needs: advocates do not file findings
- **software-development/contracts/review-artifact.schema.json** — artifact schema_version unchanged · needs: no consumer pins it; additions optional
- **software-development/flows/flow-review/scripts/render-md.sh** — bidi or zero-width characters could reorder text · needs: ingest already rejects control and format characters
