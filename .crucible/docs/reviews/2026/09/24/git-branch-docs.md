# Review: claude-code-crucible

**Repo:** claude-code-crucible  
**Started:** 2026-09-24 · **Last updated:** 2026-09-24  
**Round:** 6  
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: lens-consistency-reviewer
- Round 2: lens-consistency-reviewer
- Round 3: lens-consistency-reviewer, shell-script-reviewer
- Round 4: lens-consistency-reviewer
- Round 5: lens-consistency-reviewer, execution-test
- Round 6: execution-test

## Findings

### CONS-001 — LOW
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/git-operator/skills/standard-git-branch/SKILL.md:31

The standard justifies 'Ticket id required' only by what create-branch.sh can do, reversing the framework's rule that standards define conventions and procedures follow them. Sibling precedents (standard-git-commit:54, standard-git-branch:56) give the domain reason first and name the script as enforcement; if the script is ever relaxed, this rule is left with no reason.  
→ Fix: Lead with the domain reason (the branch traces to its issue; trackers such as Jira link by key), then add 'enforced by procedure-git-ops create-branch.sh, which refuses a branch without --ticket'.

### CONS-002 — LOW
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/git-operator/skills/standard-git-branch/SKILL.md:31

'No ticket yet? ask for one' lives only in the standard, read by the git-operator (a subagent that cannot reach the human). The framework places 'required input missing, ask the human first' in the orchestrator's flow (base :259-261, PR base :331-332, MR target :391-392, invariant :466-468); Branch Path step 1 lists the ticket id as an input with no ask-if-missing clause, though it is now as mandatory as the base.  
→ Fix: In flow-git-operations Branch Path step 1, add 'if you don't have a ticket id, ask the human first; never let the operator invent one'; optionally add the ticket to the never-default invariant at :466-468.

### CONS-003 — LOW
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/git-operator/skills/standard-git-branch/SKILL.md:63

Line 31 adds a hard prohibition (never invent a ticket id or leave it out), but the 'Constraints (NEVER violate)' section does not repeat it, unlike every standard-git-* skill, which repeats its body's hard rules there.  
→ Fix: Extend the naming Constraint at :63, e.g. '...; never create a branch without a ticket id, and never invent one'.

### CONS-004 — LOW
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/git-operator/skills/standard-git-branch/SKILL.md:12

The Workflow intro at :12 still says 'Two long-lived branches, three supporting types', while the new line :22 adds five more supporting prefixes (fix/refactor/perf/docs/chore); the count only holds if the reader infers those five share feat/*'s role.  
→ Fix: Reword :12, e.g. 'two long-lived branches and three supporting roles: feature-like (feat/* and the prefixes listed below the table), release/*, hotfix/*', or drop the count.

### CONS-005 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/flows/flow-git-operations/SKILL.md:282-285

The flow now decides 'created' vs 'no-op' by reading stderr wording ('if stderr says the branch already exists'). In this framework callers act on machine KEY=VALUE lines and exit codes; stderr is diagnostics only (create-branch.sh:44; procedure-git-identity:94; flow G5 step 6). The one other idempotent script signals its no-op with a machine key (push.sh GITOP_PUSHED=true|false). If the warning is reworded, the orchestrator silently reports an existing branch as newly created from --base.  
→ Fix: Add GITOP_CREATED=true|false to create-branch.sh, mirroring GITOP_PUSHED (a script change: shell-script developer/reviewer); document it in the procedure's Prints bullet; have flow step 4 key on it instead of stderr text.

### CONS-006 — LOW
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/git-operator/skills/procedure-git-ops/SKILL.md:40

The procedure's case-twin sentence prescribes a human-interaction step ('hand the conflict back to the human … then retry'). procedure-* skills leave post-failure judgment to 'the caller' (procedure-git-ops:56,71,97,114; procedure-gh-pr:73; procedure-glab-mr:36,140), and the flow owns asking the human; flow step 4 already says it, so the rule now lives in two places and can drift.  
→ Fix: In the procedure keep only the mechanical fact ('renames nothing; the framework has no rename/delete script; resolving the twin is the caller's decision') and leave 'hand it back to the human' to flow-git-operations step 4.

### CONS-007 — LOW
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/git-operator/git-operator.md:18

New input 7 gives only the MR scripts' --confirmed-host as the reason to pass the GitLab host. The flow also passes it on commit-only GitLab work so resolve-identity.sh can use --gitlab-host (flow-git-operations:95-108, :113; git-operator.md:59), where it may be 'degraded-to-unknown' rather than confirmed. The item's wording covers every GitLab operation but its reason does not, so an orchestrator could wrongly skip the host on a commit.  
→ Fix: Widen the reason: resolve-identity.sh's --gitlab-host needs it for any commit/tag; the MR scripts hard-require --confirmed-host; pass it as unconfirmed if the gate could not confirm a host on a commit-only request.

### CONS-008 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/git-operator/git-operator.md:18

Item 7's '(on a commit it may be unconfirmed, if the gate could not confirm one)' reads as permission to pass a host the account gate did NOT confirm as --gitlab-host, contradicting procedure-git-identity:86 (pass only a gate-confirmed host; never read it off an untrusted repository's remote URL), git-operator.md:59, and flow-git-operations:101-102 (an unconfirmable host means running resolve-identity.sh UNPINNED). Followed literally, an untrusted remote's host could fake a 'verified' email result. Introduced by the round-3 fix (wording taken from the lens's own round-3 suggestion).  
→ Fix: Replace the parenthetical with: if the gate could not confirm a host, the brief says so and carries none — resolve-identity.sh then runs unpinned and reports unknown; never pass an unconfirmed host. Optionally align flow-git-operations:107 'confirmed (or degraded-to-unknown) host'.

### CONS-009 — LOW
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/specialists/git-operator/git-operator.md:14

Item 3 says a PR/MR's ticket 'may instead be read from the branch name, which always carries it', but only branches named to standard-git-branch carry one; the PR/MR paths accept any existing head/source branch (this repo's chore/framework-improvements has none), and a normalized ticket (MY_PROJ-42 -> my-proj-42) does not read back as the issued id.  
→ Fix: Reword: may be read from the branch name when it follows standard-git-branch; if the branch carries no ticket, or only a normalized one, ask.

### EXEC-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved  
**Reviewer:** execution-test  
**File:** software-development/agents/specialists/git-operator/git-operator.md:14

Item 3's 'or only a normalized one, ask' is undecidable: standard-git-branch renders MY_PROJ-42 as my-proj-42, identical to a genuine lowercase-slug ticket, and a slug ticket has no delimiter from the description (feat/ops-incident-7-fix-x). An operator reading the ticket off such a branch can link the wrong id.  
→ Fix: Read a ticket from the branch only when it is an uppercase tracker key or a bare number right after the prefix; otherwise the orchestrator passes the issued id, or the operator asks.

### EXEC-002 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** execution-test  
**File:** software-development/agents/specialists/git-operator/git-operator.md:14

Item 3 claims an uppercase tracker key is 'the only uppercase run in a branch name, so it cannot be misread' — true only for branches create-branch.sh made. A hand-made branch like fix/CVE-2024-3094-xz or feat/UTF-8-support yields a key-shaped non-ticket (CVE-2024, UTF-8), linked silently; only the pre-consent PR body exposure catches it.  
→ Fix: Drop the 'cannot be misread' claim; have the operator state a branch-read ticket explicitly as an assumption in the plan for the human to confirm at exposure (and skip the read when the prefix is not a listed type). Tracked in task #19.

### EXEC-003 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** execution-test  
**File:** software-development/agents/specialists/git-operator/git-operator.md:14

Item 3 never says where the key ends ('uppercase run' is loose: AB2-7-3-retries must read AB2-7, which only standard-git-branch's pattern shows), and numeric tickets (feat/1-token-refresh) now always need an ask — a deliberate safety trade.  
→ Fix: Cite standard-git-branch's tracker-key pattern as the extraction boundary. Tracked in task #19.
