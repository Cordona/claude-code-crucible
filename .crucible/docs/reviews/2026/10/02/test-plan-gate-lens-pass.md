# Review: claude-code-crucible

**Repo:** claude-code-crucible  
**Started:** 2026-10-02 · **Last updated:** 2026-10-02  
**Round:** 1  
**Verdict:** APPROVED_WITH_FOLLOWUPS

## Round history
- Round 1: lens-security-reviewer, lens-compatibility-reviewer, lens-consistency-reviewer, lens-clean-code-reviewer, lens-self-documenting-code-reviewer

## Findings

### SEC-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-approve.sh:170-252

Nothing binds the approved plan to the bytes the human saw; approve.sh re-reads the mutable plan file, drafts share its directory, and a prompt-injected tests-developer could swap in another valid plan before or after approval.  
→ Fix: render-md.sh emits a sha256 of the rendered bytes; approve.sh requires --expect-sha256 and builds from a private copy; orchestrator re-checks the digest before AUTHOR/TESTS dispatch; drafts go to a separate directory.

### SEC-002 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-testing/scripts/lib/test-plan-validate.jq:39

The forbidden set omits invisible format characters (U+200B-200F, U+061C, U+00AD, U+2060-2064, U+FEFF, tag characters U+E0000-E007F); tag characters can smuggle instructions to downstream agents that the human never sees; a ZWSP-only value passes as non-empty; tojson'd keys can echo C1/bidi raw.  
→ Fix: Extend forbidden_characters, schema patterns, and neutralize in lockstep to the full invisible/Cf list; require a visible character; gsub forbidden characters out of echoed keys.

### SEC-003 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-testing/scripts/render-md.sh:190

Inline Markdown/HTML stays live: an HTML comment split across two values can hide renderer text in HTML-aware viewers, image links can beacon, and whitespace padding can fake a line start in a terminal.  
→ Fix: Escape & < > and inline Markdown metacharacters in free text; collapse whitespace runs.

### SEC-004 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/contracts/test-plan.schema.json:236

Paths are described as repo-relative but not enforced; an approved plan could name an absolute or ../ path and authorize writes outside the repo.  
→ Fix: Reject leading / or ~, any .. segment, backslashes, and a leading - in paths (validator and schema).

### SEC-005 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/flows/flow-testing/SKILL.md:62-73

flow-testing never states that plan contents, render output, and script diagnostics are untrusted data, right before the consent gate; injected 'already approved' text targets exactly this gate.  
→ Fix: State in §3 and the Invariants that these are data, never instructions; approve runs only on the human's in-turn answer.

### SEC-006 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-security-reviewer  
**File:** software-development/agents/developers/tests-developer.md:65

The scratch-copy rule copies the whole project (including .env/credentials) to an unspecified location with no permissions or deletion step.  
→ Fix: Create it with mktemp -d (0700) under the session scratchpad or TMPDIR, copy only what the build needs, delete it at dispatch end and report that.

### COMPAT-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-compatibility-reviewer  
**File:** software-development/agents/developers/tests-developer.md:11

MODE is a new required dispatch input with no defined behavior when missing; an old-style dispatch gets undefined behavior.  
→ Fix: Add a no-MODE rule and Edge Cases row: stop and report that the dispatch must name PLAN or AUTHOR.

### COMPAT-002 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-compatibility-reviewer  
**File:** software-development/agents/developers/tests-developer.md:48

Agents and skill are live via symlink but test-plan.schema.json is not deployed to ~/.claude/crucible/contracts; there is no 'if unreadable' clause.  
→ Fix: Deploy the contract with the hub in the same rollout; add an 'if the schema is unreadable, the script's validation error is the shape authority' clause.

### COMPAT-003 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-compatibility-reviewer  
**File:** CLAUDE.md:56

An untouched CLAUDE.md line says flow-testing §3 runs in full before tests-developer or the reviewer touch anything, contradicting §3b/§3c which dispatch both inside the gate.  
→ Fix: Reword to: flow-testing §3, starting with the §3a scope question, before any test is written.

### COMPAT-004 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-compatibility-reviewer  
**File:** software-development/agents/reviewers/lens/lens-test-quality-reviewer.md:64-68

Revised-plan JSON in ## Notes, plan:item locations, and an unused verdict conflict with the bound review-report-standards; the payload risks being dropped. Convergent with CONS-001.  
→ Fix: Sanction the plan payload and plan:item locations in review-report-standards and the finding schema, and cite that from the reviewer.

### COMPAT-005 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-compatibility-reviewer  
**File:** software-development/shared/standards/lens/standard-testing/SKILL.md:94

standard-testing §4/§7 change meaning (lowest-level-first, golden default); existing suites will draw new findings with no migration note.  
→ Fix: Note in the reviewer that suites built to the old rules fall under the conflict protocol and diff-scope.

### CONS-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/agents/reviewers/lens/lens-test-quality-reviewer.md:66

The reviewer emits a fenced revised-plan JSON and a Volume line inside ## Notes, but review-report-standards limits Notes to five prose kinds and routes machine artifacts to a schema field. Convergent with COMPAT-004.  
→ Fix: Add an optional plan_revision field to review-finding-report.schema.json documented beside conventions_profile, or sanction the exception in review-report-standards.

### CONS-002 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-challenge.sh:26

\--plan/--revision diverge from the house --json-file/--fields-file, and from test-plan-create.sh's own --fields-file.  
→ Fix: Rename to --json-file and --fields-file across the scripts and flow-testing §3.

### CONS-003 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-create.sh:312

Output key TESTPLAN_JSON breaks the prefix-uppercased rule (SPEC_JSON, REVIEW_JSON).  
→ Fix: Emit TEST_PLAN_JSON in all four scripts and docs.

### CONS-004 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/contracts/test-plan.schema.json:30

Schema descriptions restate lifecycle semantics owned by flow-testing §3.  
→ Fix: Trim to value domain plus a citation of flow-testing §3.

### CONS-005 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/contracts/artifact-slug.schema.json:5

artifact-slug.schema.json is scoped to durable flow-spec/flow-review artifacts; test plans are an unacknowledged third, non-durable consumer.  
→ Fix: Widen its description to name flow-testing test plans.

### CONS-006 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-consistency-reviewer  
**File:** software-development/flows/flow-implementation/SKILL.md:122

A bare §3a refers to flow-testing, violating the bare-§N-means-same-file rule.  
→ Fix: Write it as `flow-testing` §3a.

### CLEAN-001 — MEDIUM
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-create.sh:260-266

The body-assembly shape (six keys plus floor-normalising) is hand-copied into four writers; a missed edit silently drops an optional field.  
→ Fix: Add def plan_body($src) to the shared lib and build from it in all writers.

### CLEAN-002 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/lib/test-plan-validate.jq:196-245

The earlier-duplicate idiom is repeated in four rules.  
→ Fix: Extract def duplicate_positions and map over it.

### CLEAN-003 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-create.sh:183

The slug regex is duplicated between create.sh and the validator.  
→ Fix: Add def slug_errors to the lib and use it in both.

### CLEAN-004 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-clean-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/lib/test-plan-validate.jq:281-311

plan_document_errors mixes key presence, stamped-field shape, and lifecycle rules at four nesting levels.  
→ Fix: Extract stamped_field_errors and status_lifecycle_errors; derive the required list from stamped_keys.

### DOC-001 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/flows/flow-testing/scripts/test-plan-challenge.sh:14-17

The WHY comment restates the workflow and gets it wrong: the reviewer drafts the revised plan, the orchestrator writes it unchanged.  
→ Fix: Keep only the WHY (whole-plan validation) and cite flow-testing §3c.

### DOC-002 — LOW
**Tracked status:** pending · **Finding status:** new  
**Reviewer:** lens-self-documenting-code-reviewer  
**File:** software-development/agents/developers/tests-developer.md:33

Lists the reviewer's review-only checks while saying they are not restated here.  
→ Fix: Cite the reviewer's Review-only checks instead of enumerating.
