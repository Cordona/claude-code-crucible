# Review: claude-code-crucible

**Repo:** claude-code-crucible  
**Started:** 2026-10-03 · **Last updated:** 2026-10-03  
**Round:** 1  
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: lens-consistency-reviewer, lens-self-documenting-code-reviewer, lens-security-reviewer, lens-compatibility-reviewer, lens-clean-code-reviewer

## Findings

### SEC-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-testing/scripts/lib/test-plan-validate.jq

\`run` accepts any shell (; | $() redirections); a prompt-injected plan or reviewer revision can smuggle a command the human copy-pastes or an agent executes; no execution policy is stated.  
→ Fix: Reject shell metacharacters in run, state no agent executes run verbatim, require a recorded change when run differs.

### SEC-002 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-amend.sh

An amend or challenge can change run, builds_on, existing_tests, or an approved test's entry without any amendment/changes entry while the plan still shows Approved.  
→ Fix: Diff against the stored plan; require a recorded change naming each changed section and each changed approved test.

### SEC-003 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/contracts/test-plan.schema.json

existing_tests repair/delete entries are bare names with no file; a vague or wildcard name lets one approved bullet delete many tests.  
→ Fix: Require a listed file on repair/delete entries, reject wildcard characters, and delete only the named test in the named file.

### SEC-004 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-testing/scripts/render-md.sh

Some approved values are never rendered: fixture kind, the amendment's test name, parts of rejected entries.  
→ Fix: Render every approved value or drop the unrendered field.

### COMPAT-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-compatibility-reviewer  
**File:** software-development/agents/reviewers/lens/lens-test-quality-reviewer.md

The reviewer is never told an amend that removes the last end-to-end test needs a top-level no_e2e_agreed, so that path always fails validation. Convergent with CONS-002.  
→ Fix: Tell the reviewer to emit a top-level no_e2e_agreed beside amendments in that case.

### COMPAT-002 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-compatibility-reviewer  
**File:** software-development/contracts/test-plan.schema.json

The plan shape changed while schema_version stays 1.0.  
→ Fix: Bump the version or accept it as unreleased.

### CONS-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/contracts/test-plan.schema.json

British behaviour is baked into contract keys, messages and prose while the domain spells behavior (181 hits).  
→ Fix: Rename to behaviors / behavior everywhere before the contract ships.

### CONS-002 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/reviewers/lens/lens-test-quality-reviewer.md

Same gap as COMPAT-001: the reviewer body never documents the top-level no_e2e_agreed an amend requires. Convergent with COMPAT-001.  
→ Fix: Document it in the trim re-challenge and TESTS instructions.

### CONS-003 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/contracts/test-plan.schema.json

The schema restates flow-testing §3d lifecycle rules (agreement carry-forward, removed+added) despite its header assigning semantics to the flow.  
→ Fix: Reduce to shape plus a flow-testing §3d citation.

### CONS-004 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/developers/tests-developer.md

A bare (§7) points at standard-testing.  
→ Fix: Qualify it as `standard-testing` §7.

### CONS-005 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/reviewers/lens/lens-test-quality-reviewer.md

The fix-line decision vocabulary is undefined.  
→ Fix: Enumerate approved / rejected / the reviewer.changes actions.

### CONS-006 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/flows/flow-testing/SKILL.md

Only flow-testing's summary reports measured token usage; no sibling flow does.  
→ Fix: Drop it, or state how measured reporting differs from the never-price gate rule.

### CONS-007 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/contracts/test-plan.schema.json

Document-shaped sibling contracts carry a worked examples instance; test-plan does not.  
→ Fix: Add one challenged-plan example.

### CLEAN-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/contracts/test-plan.schema.json

$defs/test and $defs/proposed_test duplicate their level if/then rules.  
→ Fix: Extract a shared test_level_rules def.

### CLEAN-002 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-amend.sh

The no_e2e_agreed merge rule lives in the script while its check lives in the lib.  
→ Fix: Move the merge into a lib def beside the checks.

### CLEAN-003 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/render-md.sh

e2e_lines and unit_lines repeat the per-test layout.  
→ Fix: Extract shared heading and fixture helpers.

### DOC-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-amend.sh

The no_e2e_agreed lifecycle rule is restated in 6+ places.  
→ Fix: Keep flow-testing §3d as owner and cite it elsewhere.

### DOC-002 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/contracts/test-plan.schema.json

Schema descriptions restate rules owned elsewhere; the amend --fields-file doc is a 12-line run-on.  
→ Fix: Point at the owner; tighten the option doc.

### DOC-003 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/lib/test-plan-validate.jq

Four comments repeat what the code says.  
→ Fix: Delete them.
