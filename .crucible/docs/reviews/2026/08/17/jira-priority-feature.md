# Review: claude-code-crucible

**Repo:** claude-code-crucible
**Started:** 2026-08-17 · **Last updated:** 2026-08-17
**Round:** 1 (of 3 max)
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: lens-clean-code-reviewer, lens-consistency-reviewer, lens-compatibility-reviewer

## Findings

### CLEAN-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/cmd-bulk.sh:35-53

The update field set is enumerated three times (bulk's --plan summary + two byte-identical at-least-one-field predicates); adding --priority required editing all three, and the --plan copy is the one whose omission fails SILENTLY — a consent gate would disclose a write it never names.
→ Fix: Make bulk_update_field_summary the single source of truth: move+rename it to cmd-update.sh, add a has_update_field_request() predicate derived from it, and replace both 14-term guards with that predicate — or, minimally, extract just the duplicated predicate.

### CONS-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new
**Reviewer:** lens-consistency-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/SKILL.md:129

SKILL.md's create/update bullets gained a new user-facing flag but no new Procedure Version footer entry was added, breaking the file's own stacked-changelog convention (every content change, including doc-only ones, earns an entry).
→ Fix: Add a Procedure Version 2.5 entry directly above the 2.4 entry, in the same shape as its neighbours, describing the --priority addition and its opt-in/no-local-validation contract.

### CONS-002 — LOW
**Tracked status:** pending · **Finding status:** new
**Reviewer:** lens-consistency-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/cmd-update.sh:209

The priority merge is placed BEFORE the --parent block in cmd_update but AFTER the parent merge in cmd_create, breaking the two verbs' otherwise field-for-field parallel order, and disagreeing with validate_update_args, cmd-bulk.sh, and jira.sh's own OPT-declaration order (all list priority after parent).
→ Fix: Move the priority merge in cmd_update to just after the --parent if-block closes, restoring the create/update parallel order.

### COMPAT-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new
**Reviewer:** lens-compatibility-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/scripts/jira.sh:462

Adding --priority to the GLOBAL arg loop moves a concrete invocation from a loud rejection to a silent no-op: `transition K --status Done --priority High` (and `bulk --op transition --priority High`) used to exit 2 (unknown option) and now exits 0 with the requested priority silently dropped — the plan/consent disclosure never names the dropped flag, and the sole consumer is an AI agent that relies on the exit code as a self-correction signal.
→ Fix: Scope the --priority carrier per-command — reject it in validate_comment_args/validate_transition_args and in validate_bulk_args' non-update ops, mirroring how validate_schedule_args rejects a stray --board; or, if the global-carrier pattern is deliberately kept, document in usage.sh's --priority entry that the flag is accepted-but-inert outside create/update.
