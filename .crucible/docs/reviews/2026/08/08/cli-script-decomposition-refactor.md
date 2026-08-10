# Review: claude-code-crucible

**Repo:** claude-code-crucible
**Started:** 2026-08-08 · **Last updated:** 2026-08-08
**Round:** 2 (of 3 max)
**Verdict:** APPROVED

## Round history
- Round 1: lens-clean-code-reviewer, lens-consistency-reviewer, lens-security-reviewer, lens-test-quality-reviewer, lens-compatibility-reviewer
- Round 2: shell-script-reviewer

## Findings

### HUB-001 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer, lens-consistency-reviewer, lens-security-reviewer (independently confirmed)
**File:** deploy/hub/lib/hub-discovery.sh:201-209

hub_disc_sd_baseline classifies specialist skills by the raw basename, which is now the literal "skill" for procedure-gh-pr/procedure-glab-mr (the skill-basename unwrap was applied to hub_disc_pm but not to hub_disc_sd_baseline), so hub_sd_vcs_of returns empty, the vcs:github/vcs:gitlab groups are never created, --sd-vcs and the github-vcs/gitlab-vcs component tokens break, both PR/MR skills silently install as unconditional SD baseline, and cross-domain cascade logic misclassifies consumers.
→ Fix: Apply hub_disc_pm's identical basename-unwrap (lines 306-310) inside hub_disc_sd_baseline before calling hub_sd_vcs_of; extract the unwrap into one shared helper so a third classification site cannot miss it again.

### COMPAT-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer
**File:** deploy/hub/lib/hub-symlink.sh:123-137

Every already-installed target's symlink still points at the old procedure-X source path; after this move hub_path_state will read all 5 refactored skills as DIVERGED on the next install/upgrade run, and the upgrade path was never exercised (only a fresh scratch --target was tested).
→ Fix: Verify the upgrade path against a target installed from the pre-move tree and document the required re-run (accepting the diverged re-sync) in the release/handoff notes.

### CONS-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/scripts/cmd-vote.sh:7

Jira's 26 cmd-*.sh are sourced-only fragments (never directly invoked) but sit in skill/scripts/ next to the real entry points, breaking the scripts=invokable / lib=sourced-only convention every sibling family follows.
→ Fix: Move the 26 cmd-*.sh under skill/lib/ (or skill/lib/commands/) and source them from $LIB_DIR, leaving skill/scripts/ holding only jira.sh + md-to-adf.sh.

### CONS-003 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer, lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/SKILL.md:10-12

procedure-jira's SKILL.md was never updated for the decomposition: it still asserts jira.sh is self-contained, argues against the sourcing rule the refactor deliberately relaxed, documents no lib/ section, carries no version/changelog bump, lists only 14 of the 26 actual commands, and contains two factual errors (a removed --resolution default, and JIRA_WATCHING vs the real JIRA_WATCHED key).
→ Fix: Rewrite SKILL.md: add a lib/ section mirroring the sibling SKILL.mds, delete the stale self-contained claims, regenerate the command list from usage.sh, delete the removed-behavior sentence, correct the watch output key, and bump the version footer with a changelog entry.

### CONS-004 — MEDIUM
**Tracked status:** pending · **Finding status:** ack
**Reviewer:** lens-consistency-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/http.sh:1

Three unrelated lib/ naming schemes exist for the same structural role (plain in Jira, pm-* in gh/glab-issues, skill-name-prefixed in gh-pr/glab-mr) with no stated rule, and the split isn't explained by domain since procedure-jira and procedure-gh-issues share one domain yet differ.
→ Fix: Pick one naming rule and record it in the layout convention doc; recommend the plain, role-descriptive form since lib/ is per-skill-private and never cross-sourced, so any prefix just repeats the path.

### CONS-005 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/scripts/jira.sh:213-214

jira.sh resolves SCRIPT_DIR via dirname/cd/pwd while all four sibling families resolve theirs by pure parameter expansion specifically because dirname/readlink/realpath/basename are excluded from the test toolbox; the refactor made this weaker idiom load-bearing for all 43 newly sourced units.
→ Fix: Replace jira.sh's SCRIPT_DIR derivation with the siblings' case "$0" in */) ... esac parameter-expansion form.

### SEC-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/skill/lib/pm-glab-url.sh:80-120

The GitLab issue/MR URL-candidate extractors anchor the project path but never constrain the host, so a same-path/same-iid URL on an attacker-controlled host can pass validation and be relayed as the genuine issue/MR URL.
→ Fix: Require the confirmed host as a third parameter and compare each candidate's authority component literally before stripping it; wire --confirmed-host through every glab-issues call site and update-mr.sh, and derive it from the repo remote for create-mr.sh.

### TEST-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/run-write-tests.sh:1524-1583

The 'token never on argv' test block is 9 purely negative assertions with no exit-code or call-count control, so a command that regressed to exit before its first curl call would pass vacuously.
→ Fix: Add expect_rc and a positive call-count/argv_log_has_token assertion to each of the 9 cases, matching run-engine-tests.sh:395-400's pattern.

### TEST-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/check-variable-collisions.sh:84-281

The new variable-collision gate has no self-test: an empty derived table or a regex that stops matching after a layout change degrades silently to 'no collisions found' + exit 0, with nothing to distinguish a clean codebase from a broken analyzer.
→ Fix: Add a fixtures/varcheck/ pair (one known-dangerous collision, one known-safe shared name), point the script at it via an env override, and assert exit 1 / exit 0 respectively; fail loudly if the derived funcs/calls tables come back empty.

### TEST-003 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** project-management/agents/project-manager/skills/procedure-gh-issues/tests/run-tests.sh

Only Jira's test harness proves the new $0-relative lib resolution survives the real deploy shape (an unrelated cwd + a symlinked skill/ dir); the other four families gained the identical resolution but only invoke scripts by absolute repo path, so a resolution regression is invisible until the first real operation.
→ Fix: Port Jira's two deploy-shape probes (cwd change + symlink-through) into all four remaining harnesses.

### TEST-004 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/run-engine-tests.sh:59-292

~150 lines of test-harness mechanics (curl stub, runner primitives) are copy-pasted verbatim across three Jira test files in the same directory and have already drifted (one copy supports -D header dumps the others lack).
→ Fix: Extract tests/lib/harness.sh + tests/lib/curl-stub.sh and dot-source them from all three test files; the production-side duplication rationale (independent skill deployment) doesn't apply to tests/, which is never deployed.

### TEST-005 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/run-engine-tests.sh:3242-3331

The P4 test driver reconstructs jira.sh's state by sed-scraping between two variable-name sentinels; any behavior-preserving rename/reorder of those lines silently empties the range and turns 26 checks into unbound-variable failures, and it asserts ACCEPT paths only (a gutted validator would pass all 26).
→ Fix: Bracket the initializer block with stable marker comments instead of variable names, assert the extracted block is non-empty before sourcing, and pair each accept case with a reject case.

### TEST-009 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** software-development/agents/specialists/git-operator/skills/procedure-gh-pr/tests/run-tests.sh:503-554

The accumulate() characterization set never tests a list token containing a space or an all-separator value -- exactly the properties accumulate's newline-separated-list design exists to preserve.
→ Fix: Add a --label 'needs review' case (asserted as one token) and a --label ',,' case (asserted to produce no token) to both create-pr.sh and update-pr.sh sections, and mirror into glab-mr's harness.

### CLEAN-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/scripts/jira.sh:3-198

jira.sh's own header still claims it is self-contained ('sources nothing') and describes fourteen commands, directly contradicting the 43-unit sourcing loop and 26-command dispatch table that ships in the same file.
→ Fix: Rewrite the header to describe the dispatcher + lib/ + cmd-*.sh shape and replace the 'sources nothing' claim with the real source list.

### CLEAN-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/usage.sh:13-44

usage.sh's header carries a second, already-drifted CLI synopsis (14 commands) duplicating the real usage() function 140 lines below it (26 commands).
→ Fix: Delete the header synopsis; keep only a one-line pointer to usage() as the single source of truth.

### CLEAN-003 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/scripts/cmd-transition.sh:414-415

require_ticket_positional was extracted for exactly this prelude but 5 of 8 candidate sites still hand-roll the identical text instead of calling it.
→ Fix: Replace each hand-rolled pair with a call to require_ticket_positional (output is byte-identical).

### CLEAN-004 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/search-core.sh:36-39

Several lib/ units use bare scratch names (jql, out_file, config_file, key, value) that runtime.sh's own stated naming convention forbids; one collision is already live in a real call chain (cmd_search's jql is reassigned inside build_search_request_body), and the split raised the cost of checking uniqueness from one file to 43.
→ Fix: Prefix each lib function's scratch names per-function as the cmd-*.sh files already do.

### CLEAN-005 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/scripts/cmd-schedule.sh:29-55

Several extracted command files kept the old monolith's section banner underneath their new file header, and the banners have already started drifting from the code (cmd-watch's banner still documents vote's endpoint, which now lives in cmd-vote.sh).
→ Fix: Delete each redundant banner, folding in only the parts that add information not already in the new header.

### CLEAN-006 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-gh-issues/skill/scripts/create-issue.sh:188-198

The mktemp+trap+stderr-indent idiom for capturing tool stderr is repeated verbatim across all 7 scripts in both issue families, while the sibling git-operator skills already prove the extraction is cheap (init_tmp_err/emit_captured_stderr).
→ Fix: Add init_tmp_err/emit_captured_stderr equivalents to each family's own pm-diag.sh and call them from all 14 scripts.

### CLEAN-007 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** software-development/agents/specialists/git-operator/skills/procedure-glab-mr/skill/scripts/find-mr.sh:210-217

Both glab families extracted a count_lines helper and then re-implemented it inline at 4 more sites, each carrying its own copy of the same explanatory comment.
→ Fix: Call count_lines at all four sites, and relocate glab-issues' count_lines to pm-diag.sh (a unit every script already sources) instead of the URL-named lib that currently hides it.

### CLEAN-008 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-gh-issues/skill/scripts/link-children.sh:126-129

gh-issues' own append_line helper (in pm-lists.sh) is hand-rolled inline at 4 sites instead of called; glab-issues has the identical gap despite its pm-lists.sh header explicitly discussing this exact idiom.
→ Fix: Source pm-lists.sh in link-children.sh/ensure-labels.sh and replace each hand-rolled append with a call to append_line, in both families.

### CLEAN-009 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/skill/scripts/comment.sh:295-310

The URL-candidate/iid-cross-check resolution block is duplicated between comment.sh and update-issue.sh with the same policy, and the two copies have already drifted (one strips a '#note_' anchor before comparing, the other doesn't).
→ Fix: Extract pm_url_matching_iid(candidates, iid) into pm-glab-url.sh and call it from both sites.

### CLEAN-016 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/skill/scripts/find-duplicate.sh:100

find-duplicate.sh sources the labels-named lib for one generic jq-normalizer function it needs, inheriting label-pagination constants it never uses -- a boundary problem the implementing session's own 'harmless' disclosure doesn't resolve.
→ Fix: Move pm_strip_jq_quotes to pm-diag.sh (or a new pm-glab-jq.sh) and drop the pm-glab-labels.sh source from find-duplicate.sh.

### COMPAT-003 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-compatibility-reviewer, lens-consistency-reviewer
**File:** software-development/agents/developers/tests-developer.md:18

Both a deployed agent body and the backlog doc still reference the pre-move path procedure-jira/scripts/jira.sh (now procedure-jira/skill/scripts/jira.sh), and CONTINUATION.md locates several cmd_* functions 'in jira.sh' when they now live in their own cmd-*.sh files.
→ Fix: Insert the /skill/ segment in both paths and repoint CONTINUATION.md's bullet at the actual per-command files.

### CONS-007 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/agents/specialists/git-operator/skills/procedure-gh-pr/skill/SKILL.md:84

Both git-operator SKILL.md footers declare a version number that their own changelog line immediately contradicts (e.g. declares 1.2 then changelog says '1.3 decomposes...').
→ Fix: Bump the declared footer versions to 1.3 and 1.1 respectively, matching their own changelog lines.

### CONS-008 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/skill/SKILL.md:66

glab-issues nests its lib/ subsection under the wrong parent heading ('The other GitLab divergences' instead of 'The seven scripts'), unlike every sibling SKILL.md.
→ Fix: Move the lib/ subsection to be a child of 'The seven scripts', matching gh-issues/gh-pr/glab-mr.

### CONS-009 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/validate.sh:1-2

Three different header conventions exist for sourced-only files in the same pass (shebang+directive, directive-only, neither), even though gh-pr-common.sh states outright that a sourced-only file should carry no shebang.
→ Fix: Standardize: no shebang, '# shellcheck shell=sh' directive present, on every sourced-only file across all 5 families.

### CONS-010 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-consistency-reviewer
**File:** software-development/agents/specialists/git-operator/skills/procedure-glab-mr/skill/scripts/create-mr.sh:160-166

glab-mr's lib-guard loop uses a bare, never-unset 'lib' variable where the PM families use a prefixed, unset-after-use variable -- a live collision risk in a family with one flat POSIX namespace -- and its shellcheck source directive form differs from the PM families'.
→ Fix: Rename the loop variable to a prefixed name and unset it after the loop; standardize the shellcheck source directive to the SCRIPTDIR form repo-wide (the technically-correct one).

### SEC-003 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/http.sh:46

All three curl invocations place --proto '=https' before -K "$CURL_CONFIG_FILE", so any directive inside that config file (a future insecure/proxy/location option) would override the hardening flags that precede it on the command line.
→ Fix: Reorder so -K comes immediately after 'curl -sS' and hardening flags like --proto come after it, in all three call sites.

### SEC-004 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-security-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/issue-set.sh:79

Two diagnostics interpolate API-derived values directly into terminal output without the strip_control_ansi treatment every sibling call site applies, even though these two values reach that branch precisely because they failed a shape check.
→ Fix: Pipe both values through strip_control_ansi before interpolating, matching cmd-create.sh:145's pattern.

### TEST-006 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/run-engine-tests.sh:3340-3356

The single-curl-transport security gate matches an exact string ('curl -sS'), so a harmless reformatting of a future curl call (extra space, different flag order) would silently escape detection.
→ Fix: Match the command invocation pattern rather than the exact flag string.

### TEST-007 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/run-engine-tests.sh:400

A positive '-K' flag check uses a substring helper instead of the token-exact helper the same file defines and correctly uses ten lines later.
→ Fix: Replace with argv_log_has_token for that assertion.

### TEST-008 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** project-management/agents/project-manager/skills/procedure-gh-issues/tests/run-tests.sh:45

These two harnesses still resolve LIB_DIR without the readability-guard/preflight fix already applied to the gh-pr/glab-mr harnesses in round 1, so a missing lib file surfaces as hundreds of identical unreadable failures or a raw cd-abort instead of one clear diagnostic.
→ Fix: Port the two-line guard fix and a per-lib-file preflight check into both harnesses.

### TEST-010 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-test-quality-reviewer
**File:** software-development/agents/specialists/git-operator/skills/procedure-gh-pr/tests/run-tests.sh:368-369

Machine-key assertions like 'PM_PR_COUNT=1' are unanchored substrings that would also pass on PM_PR_COUNT=10, even though the same harness already uses anchored regex correctly elsewhere.
→ Fix: Use the anchored stdout_re helper for all key=value machine-line assertions.

### CLEAN-011 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/scripts/jira.sh:358

The dispatcher's generic positional TICKET_KEY holds a numeric board/sprint/epic id in seven agile commands, reading as a ticket key being used where a board id is expected.
→ Fix: Rename the dispatcher's positional to POSITIONAL_ARG, or alias it once per agile command right after validation.

### CLEAN-012 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-gh-issues/skill/scripts/update-issue.sh:137-144

Accumulator comments describe the pre-extraction design, including naming a function 'accumulate' that doesn't exist in this family (it's csv_accumulate).
→ Fix: Update the comments to match the real csv_accumulate call and its two-line form.

### CLEAN-013 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/lib/agile-paging.sh:121-135

agile_paginate is a one-statement wrapper over fetch_paginated_agile with no other caller, adding an extra hop with a doc block that just restates the inner function's.
→ Fix: Collapse to one public function name.

### CLEAN-014 — LOW
**Tracked status:** pending · **Finding status:** ack
**Reviewer:** lens-clean-code-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/skill/scripts/cmd-transition.sh:48-418

Every cmd-*.sh runs helpers-first / cmd_X-near-end / validate_X_args-last, opposite the newspaper/stepdown convention -- presented by the reviewer as a discretionary convention question, not a defect.
→ Fix: Optional: reorder to validate_X_args, cmd_X, then helpers in first-call order, if the team wants to adopt the stepdown convention here.

### CLEAN-015 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** lens-clean-code-reviewer
**File:** deploy/hub/lib/hub-discovery.sh:306-311

After the skill/-unwrap fix, the variable hdp_basename no longer holds an actual basename on the branch the fix introduced, so the name now contradicts its value.
→ Fix: Rename to hdp_skill_name (and hdp_parent to hdp_skill_dir).

### HGATE-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** deploy/hub/lib/hub-discovery.sh:400-422

While fixing HUB-001, a third classification site (hub_disc_shared, the accounts/ domain walk) was found to share the identical raw-basename-classification + -maxdepth 2 bug, undiscovered until now because no accounts/ skill uses the skill/ layout yet.
→ Fix: Routed hub_disc_shared through the same shared hub_disc_skill_name helper and bumped its walk to -maxdepth 3; verified zero behavior change on the current tree and a reproduced-then-fixed regression on a synthetic accounts/ skill.

### JGATE-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/check-variable-collisions.sh

The new variable-collision self-test gate's Pass 1 matched only line-initial assignments, missing ~30 mid-line forms (`|| x=`, `then x=`, `; x=`) already live in the codebase.
→ Fix: Rewrote Pass 1's statement-start detection to recognize assignments after `;`/`&&`/`||`/`(`/`{`/backtick/keyword, with a fixture proving both the true-positive gain and rejection of jq-program false positives.

### JGATE-002 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/run-engine-tests.sh

The suite's claimed portability backstop (dirname/readlink/realpath/basename excluded from the test PATH) was false for dirname, which was actually present, so a regression to dirname-based path resolution would pass silently.
→ Fix: Removed dirname from the engine and write-test toolboxes; kept it only in the rig toolbox (which genuinely needs it) with a documented reason. Proved the backstop is now real by reintroducing a throwaway dirname regression and confirming it broke the suite.

### JGATE-003 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/run-engine-tests.sh

The single-curl-transport security gate could be evaded by a line-continuation or URL-first curl call shape.
→ Fix: Added continuation-folding and widened the invocation-shape matcher, with new probes for both evasions plus a negative control.

### JGATE-004 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/check-variable-collisions.sh

The mid-line-assignment fix from JGATE-001 still missed case-branch prefixes (`PATTERN) name=value`), leaving 11 more live writes invisible to the gate.
→ Fix: Added a rule accepting a `)`-terminated prefix with no unmatched `(` before it; verified against all 11 real sites and against command-substitution false-positive shapes, with a permanent fixture pair added.

### JGATE-005 — MEDIUM
**Tracked status:** pending · **Finding status:** ack
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/check-variable-collisions.sh

The one-line-function-body branch of the collision scanner also drops that function's outgoing call edges and reads, not just its assignments as documented — inert today (no live case exercises it), found during round-3 review of JGATE-004.
→ Fix: Acknowledged, not fixed this pass, per the reviewer's own recommendation to stop the recursive hardening loop now that the gap-space is bounded and enumerated. Candidate for a future bounded pass if the repo-wide lib/ convention rollout proceeds.

### JGATE-006 — LOW
**Tracked status:** pending · **Finding status:** ack
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/check-variable-collisions.sh

The case-branch rule from JGATE-004 is anchored at line start, so any earlier `(` on the same line suppresses it, not just the leading-paren form documented. Zero live instances today.
→ Fix: Acknowledged, not fixed — same stopping-point rationale as JGATE-005.

### JGATE-007 — LOW
**Tracked status:** pending · **Finding status:** ack
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-jira/tests/check-variable-collisions.sh

A header comment describing one under-report gap slightly mischaracterizes the mechanism (says a second writer would be invisible; actually the collision itself goes unreported since only one write is recorded).
→ Fix: Acknowledged, documentation wording nit — not fixed this pass.

### IGATE-001 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/skill/lib/pm-glab-url.sh

The SEC-002 host-authority fix (case-sensitive compare) would false-reject a legitimate URL differing only by ASCII case, causing create-issue.sh to falsely report failure on an already-completed, unretractable create.
→ Fix: Both extractors now fold ASCII case on the authority comparison via tolower(); port comparison deliberately kept literal pending live self-managed-instance verification, documented in SKILL.md.

### IGATE-002 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-gh-issues/tests/run-tests.sh

TEST-008's per-lib preflight guard tested existence ([ -f ]) rather than readability, diverging from every command script's own [ -r ] preflight.
→ Fix: Both guards changed to [ -r ]; mutation-verified in both directions (fires on unreadable file, silent mass-failure confirmed under the old form).

### IGATE-003 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/tests/run-tests.sh

Two comments in the glab-issues test file referenced a non-existent `accumulate` helper (the real one is csv_accumulate), missed by CLEAN-012's original scope which covered only scripts.
→ Fix: Corrected both comments to csv_accumulate.

### IGATE-004 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/skill/SKILL.md

SKILL.md claimed 'the two scripts that mktemp additional files' when only link-children.sh does this in this family.
→ Fix: Reworded to name link-children.sh specifically.

### IGATE-005 — MEDIUM
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/tests/run-tests.sh

IGATE-001's host case-fold fix had zero automated test coverage — the fix was deletable with the suite fully green.
→ Fix: Added 5 new test cases (13 checks) covering both directions of the case-fold and the dedup-normalization fix (IGATE-006); each mutation-verified to genuinely fail when the corresponding fix is reverted.

### IGATE-006 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/skill/lib/pm-glab-url.sh

IGATE-001's case-fold created a side effect: URL-candidate dedup keyed on the raw token, so two case-variant spellings of the SAME url now survived as distinct candidates, falsely triggering the ambiguity guard on a completed create.
→ Fix: Dedup now keys on a case-normalized form (scheme + tolower(authority) + path) while still printing the original first-seen spelling; verified the over-collapse guard (genuinely different iids still fail closed) is intact.

### PGATE-001 — LOW
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** software-development/agents/specialists/git-operator/skills/procedure-gh-pr/tests/run-tests.sh

New negative argv assertions (added for TEST-009) used whole-file grep, which also scans a body-text payload block in the same log, risking corruption by a coincidentally-matching fixture line.
→ Fix: Ported the sibling glab-mr harness's ARGV-block-scoped, ENVIRON-based argv_has_token/argv_has_pair helpers into both gh-pr and gh-issues, converting all 13 and 11 affected sites respectively; poison-fixture-proved the old form was exploitable and the new form immune.

### PGATE-002 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** software-development/agents/specialists/git-operator/skills/procedure-gh-pr/tests/run-tests.sh

The ported argv_has_token/argv_has_pair helpers compared via awk's bare ==, which does numeric (strnum) comparison, so a logged '0100' would wrongly match a searched '100'. A live instance was found in glab-issues (--per-page 100 assertion) that would have let a real regression ship silently.
→ Fix: Forced string comparison via string concatenation on both sides of the compare, in all 4 harnesses; proved a real emitted-zero-padding regression now correctly fails where it previously passed 667/667 green.

### PGATE-003 — HIGH
**Tracked status:** approved · **Finding status:** resolved
**Reviewer:** shell-script-reviewer
**File:** software-development/agents/specialists/git-operator/skills/procedure-glab-mr/tests/run-tests.sh

The same strnum comparison bug (PGATE-002) existed in a separate helper, argv_first_is, which specifically asserts numeric MR/issue iids -- the highest-risk instance of this defect class.
→ Fix: Applied the identical string-forcing fix plus migrated the value to ENVIRON; proved a zero-padded-iid corruption bug would have shipped silently under the old form (328/328 green) and correctly fails under the new form.

### PGATE-004 — MEDIUM
**Tracked status:** pending · **Finding status:** ack
**Reviewer:** shell-script-reviewer
**File:** project-management/agents/project-manager/skills/procedure-glab-issues/tests/run-tests.sh

close-issue.sh's pre-close note leg has no argv_first_is/argv_has_pair assertion on its iid/--repo, so a leg-local positional corruption there would be invisible -- found during PGATE-003's re-review.
→ Fix: Acknowledged as a documented coverage-gap follow-up rather than reopening the loop again, per the reviewer's own proportionality judgment (the leg is correct today; only a hand-edited future mutation would slip through).
