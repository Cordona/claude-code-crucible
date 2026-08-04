# Review: claude-code-crucible

**Repo:** claude-code-crucible
**Spec:** .crucible/docs/specs/2026/07/30/crucible-management-hub-ui.json
**Started:** 2026-07-30 · **Last updated:** 2026-07-30
**Round:** 3 (of 3 max)
**Verdict:** APPROVED

## Round history
- Round 1: shell-script-reviewer, lens-clean-code-reviewer, lens-consistency-reviewer, lens-observability-reviewer, lens-performance-reviewer, lens-security-reviewer
- Round 2: shell-script-reviewer, lens-clean-code-reviewer, lens-consistency-reviewer, lens-observability-reviewer, lens-performance-reviewer, lens-security-reviewer
- Round 3: shell-script-reviewer, lens-performance-reviewer, lens-consistency-reviewer

## Findings

### SHELL-001 — CRITICAL
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** deploy/hub/lib/hub-symlink.sh:57-75

hub_symlink_item (install-side write) has no equivalent of hub_unlink_item's foreign-vs-framework-owned classification; once ALLOW_DIVERGED=1 (set for every selectively-installed item), it rm -rf's and overwrites any occupant of the target path, framework-owned or not
→ Fix: give hub_symlink_item the same stage-1/2/3 classification hub_unlink_item already has, and only honor ALLOW_DIVERGED for the framework-owned-wrong-target case

### SHELL-002 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** deploy/hub/hub-install.sh:386-389

both bulk --all flows pass ALLOW_DIVERGED=0 unconditionally, so DIVERGED items are never re-synced/removed in bulk mode, breaking the spec-promised Replace/full-removal behavior and its own preview arithmetic
→ Fix: once SHELL-001's classification exists, use it in bulk flows too so framework-owned diverged items are re-synced/removed, and only genuinely foreign occupants are protected

### SHELL-003 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** deploy/hub/hub-accounts.sh:110-117

VAR=$(cmd|grep|sed) || VAR=default never falls back on real failure under plain POSIX sh (no pipefail — pipeline status is the last stage's only), so a delegate crash yields an empty string instead of the documented false, violating the HUB_*=true|false contract and crashing --format=json's jq --argjson on empty input
→ Fix: check the delegate script's own exit status (or test its output file is non-empty) before parsing, instead of relying on || after a multi-stage pipe

### SHELL-004 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** deploy/hub/lib/hub-nav.sh:48-73

hub_confirm's header comment claims unrecognized input is re-prompted once then defaulted, but the implementation never re-prompts, and the safe (default-Yes) tier silently declines on garbage input instead of defaulting Yes
→ Fix: implement the documented retry-then-default behavior, or correct the comment to describe the actual single-shot decline-on-anything-but-explicit-yes behavior

### SHELL-005 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** deploy/hub/lib/hub-graph.sh:191

a die() inside hub_graph_forward_deps/hub_graph_locate would still be masked behind a pipe or an if-condition command substitution in two spots (set -e blind spot); not currently reachable given today's call order
→ Fix: redirect to a file and check status explicitly instead of piping/testing directly, so a future call-order change can't silently swallow the failure

### CLEAN-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** deploy/hub/hub-list.sh:89-101

the status-counts KEY=value read and the Core status line's text are duplicated verbatim across crucible-hub, hub-list.sh, and hub-doctor.sh
→ Fix: add hub_status_counts_read() to lib/hub-status.sh and hub_render_core_line() to lib/hub-render.sh; call both from all three sites

### CLEAN-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** deploy/hub/hub-list.sh:64-87

the shared --target/--source/--format/--no-color/-h flag-parsing cases and format validation are near-verbatim duplicated across 4 capability scripts
→ Fix: add hub_try_common_opt() + hub_validate_format() to lib/hub-common.sh; call first in each script's own arg loop

### CLEAN-003 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** deploy/hub/hub-doctor.sh:214-215

hub-doctor.sh invokes 'hub-accounts.sh status' twice (once per field it needs) instead of capturing the one report once, doubling the underlying gh/jira auth checks on every Doctor run (found by both: Lens Clean Code + Lens Performance)
→ Fix: capture 'status --format=env' once into a temp file/var and grep both fields from that one capture

### CONS-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** deploy/hub/lib/hub-common.sh:1

the claimed disclosed-exception paragraph naming the project's no-sourcing rule was never actually added to hub-common.sh's header (verified absent by direct grep) -- the sourced lib/ remains an undisclosed departure from the jira.sh one-dispatcher precedent
→ Fix: add the paragraph to hub-common.sh's header now, using the file's own adjacent 'WHY reimplemented rather than sourced from deploy.sh' paragraph (lines 14-22) as the template for how this project discloses a deliberate deviation

### CONS-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** roles/common/skills/accounts/procedure-git-auth/SKILL.md:1

verified true that hub-accounts.sh calls both relocated scripts directly by path (project-manager is genuinely not the sole consumer), but no artifact in the repo states this -- both SKILL.md descriptions still read as project-manager-only, and hub-tiers.tsv's comment defers to a non-existent 'implementation report'
→ Fix: state the real 2-consumer reason directly in both SKILL.md descriptions, not only in an ephemeral report that isn't a persisted file

### OBS-001 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-observability-reviewer
**File:** deploy/hub/hub-install.sh:454-469

HUB_STATUS=ok is emitted unconditionally in env/json even when items were foreign-blocked, with no itemized blocked names in machine format — an agent caller cannot detect or act on the partial failure
→ Fix: emit a distinguishing status/reason when foreign_blocked_count>0, and itemize blocked names in env/json (e.g. HUB_FOREIGN_BLOCKED_ITEMS)

### OBS-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** deploy/hub/hub-install.sh:45-52

code-side header comment now fixed, but the durable spec artifact's closed HUB_BLOCKED_REASON vocabulary still asserts only 2 values and explicitly claims no third exists, contradicted by the shipped dependency_unresolved value
→ Fix: add dependency_unresolved to the spec draft's closed-vocabulary statement (crucible-management-hub-ui-draft.md line 9) and, if warranted, the durable JSON/MD spec pair

### OBS-003 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-observability-reviewer
**File:** deploy/hub/hub-doctor.sh:247-280

Doctor's --format=env/json exposes only aggregate counts; the itemized tool names/reasons/hints and diverged item names that make the text output actionable are absent from the machine-readable sibling
→ Fix: add itemized fields (HUB_MISSING_TOOL_<N>_NAME, HUB_DIVERGED_ITEMS) mirroring List's HUB_ITEM_<N>_* convention

### OBS-004 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-observability-reviewer
**File:** deploy/hub/lib/hub-discovery.sh:91-100

a SKILL.md missing 'name:' frontmatter is silently skipped (stderr warn only) and never counted as discovered or surfaced as unclassified, contradicting this codebase's own no-silent-drop design goal
→ Fix: route this case through the same unclassified surfacing Doctor already gives naming-mismatched items instead of a stderr-only warn

### PERF-001 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-performance-reviewer
**File:** deploy/hub/crucible-hub:59-61

hub_discover_by_tier's full scan is never cached: the Main-menu render calls it twice on every single loop iteration, and list/doctor each call it 3-5x per run — the same bug class as the cascade-uninstall fix, in a different code path never touched by that fix
→ Fix: add a status-snapshot cache mirroring hub_graph_build_cache: scan once per invocation/render, classify every item's tier once, have every caller read that one cached table

### PERF-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-performance-reviewer
**File:** deploy/hub/hub-install.sh:231-241

per-item lookup helpers re-scan the entire selection table with awk on every call inside the bucketing/apply loops, making bulk install/uninstall O(n^2) in discovered-item count instead of O(n)
→ Fix: carry kind/src alongside name when the selection table is built (or index it once) so each loop reads fields directly instead of re-scanning via a lookup function

### SEC-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** deploy/hub/lib/hub-symlink.sh:19-25

a discovered component name (from scanned frontmatter, trusted only via --source) is interpolated into a filesystem path with no character/shape validation, enabling path traversal / arbitrary symlink write if --source is ever pointed at a less-trusted tree
→ Fix: reject any discovered name containing '/', a leading '.', or control bytes before it reaches hub_target_path; classify it unclassified instead

### SEC-002 — LOW
**Tracked status:** approved · **Finding status:** ack
**Reviewer:** lens-security-reviewer
**File:** deploy/hub/lib/hub-symlink.sh:46-84

a TOCTOU window exists between hub_item_state's check and the later rm/ln action; low real-world impact since exploitation needs same-user write access already
→ Fix: re-verify state immediately before acting, or accept as documented low-risk same-user race

### PERF-003 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-performance-reviewer
**File:** deploy/hub/hub-install.sh:128-134

hub-install.sh and hub-uninstall.sh only build hub_graph_build_cache (the dependency-graph cache); they never call hub_discovery_build_cache, so every hub_discover_by_tier call (3x in hub-install.sh, 2-3x in hub-uninstall.sh) still triggers a full fresh agents+skills filesystem scan -- the same bug PERF-001 fixed, left open in these two scripts
→ Fix: call hub_discovery_build_cache "$FRAMEWORK_ROOT" once near the top of both scripts, alongside the existing hub_graph_build_cache call, mirroring hub-list.sh/hub-doctor.sh

### SHELL-006 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** deploy/hub/lib/hub-graph.sh:316

hub_graph_build_dependents_index still assigns hub_graph_forward_deps|awk|tr|sed via command substitution, masking an internal die() under no-pipefail sh (same class SHELL-005 fixed elsewhere, at a third call site never named in the original finding; not reachable today)
→ Fix: redirect hub_graph_forward_deps output to a file and check its exit status explicitly, as done at hub-graph.sh:205 and :221
