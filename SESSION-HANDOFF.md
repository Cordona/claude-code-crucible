# Session Handoff — CLI Script Monolith Decomposition

**Branch:** `refactor/decompose-cli-script-monoliths` (branched from `main` at `d14567c`, which already includes PR #6 — domain layout + Crucible Management Hub + GitLab parity)
**Status:** Implementation + fix loops + live verification complete. Committed and pushed to `origin/refactor/decompose-cli-script-monoliths`, with a PR opened against `main`.
**Working-tree diff:** see the PR for the final file/line counts — this document predates two Jira features (task-list ADF support, `version --delete`) added later in the same session.

Read this whole document before touching anything — several decisions below were made deliberately and should not be re-litigated without a real reason.

---

## 1. What this session did

**The ask:** three shell-script monoliths (`procedure-jira`, `procedure-gh-issues`+`procedure-glab-issues`, `procedure-gh-pr`+`procedure-glab-mr`) had grown either too large (jira.sh, 5,376 lines / 26 commands in one dispatcher) or too duplicated (~285–695 lines of byte-identical plumbing repeated per command file). Goal: decompose into small, SRP, DRY scripts, and separate test code from what the hub deploys — without changing behavior.

**Design phase (already reviewed, see `.crucible/docs/reviews/` if a comparable folder exists — check `git log` on this branch's design-discussion messages if you need the original rationale):** three independent `software-architect` passes produced evidence-backed decompositions for each family, each required to cite real `file:line` duplication, verify byte-identity with `diff`, and produce a staged, behavior-preserving verification plan. All three independently converged on the same pivotal call: **one shared `lib/` per family, never shared across families** — because the hub's `hub-symlink.sh` deploys each skill directory independently, so a cross-family `source` would fail only at runtime, invisibly past a green test suite, the day someone installs one skill without its sibling.

**Layout convention locked for this pass:**
```
procedure-<name>/
├── skill/              ← the ONLY thing the hub symlinks (contains SKILL.md)
│   ├── SKILL.md
│   ├── scripts/
│   └── lib/            ← new, only where a decomposition added one
└── tests/               ← UNCHANGED location, still a sibling — never symlinked, never installed
    ├── run-tests.sh      ← only the SCRIPTS_DIR line changed: ../scripts → ../skill/scripts
    └── fixtures/
```
This achieves "tests never installed to `~/.claude`" and "clean prod/test separation" with **zero hub symlink-mechanism changes**, because the hub's skill-naming is frontmatter-driven (`SKILL.md`'s own `name:` field), not derived from the directory basename. **This convention currently applies ONLY to the 5 skills below — it is NOT yet applied repo-wide.** See §4.

**Implementation phase:** three `shell-script-developer` dispatches, each executing one family's design exactly, each running its own staged verification (baseline → layout-only move → characterization tests for anything about to change behaviorally → extract-one-thing-at-a-time with real `diff` proofs → symlink-through-a-scratch-deployment smoke test). Then a `shell-script-reviewer` tech-pair round per family (capped at 3 rounds; none needed more than 1).

**Partway through, this session hit the 200-subagent spawn cap.** Everything up to and including the GH-PR/GL-MR review round was done via dispatched agents. Everything after that (GH+GL-issues review, all of Jira's review, the lens-equivalent pass, and final verification) was done **directly by the orchestrating session** — reading files, re-running test suites, running `shellcheck` itself, rather than trusting agent self-reports blindly. This is disclosed because it changes what "already reviewed" means for those two families — see §3.

### 1a. Jira (`project-management/agents/project-manager/skills/procedure-jira/`)
`jira.sh` (5,376 lines, 26 `cmd_*` functions) → `skill/scripts/jira.sh` (531-line dispatcher: argv parsing, command recognition, unit-sourcing, precondition order, dispatch — **no command logic**) + `skill/lib/*.sh` (17 files: `runtime.sh`, `usage.sh`, `sitegate.sh`, `credentials.sh`, `http.sh` — the *only* file that calls `curl`, `validate.sh`, `projectconfig.sh`, `accounts.sh`, `jql.sh`, `adf.sh`, `inline-images.sh`, `fields.sh`, `refs.sh`, `search-core.sh`, `agile-paging.sh`, `issue-set.sh`, `batch-report.sh`) + `skill/lib/cmd-*.sh` (26 files, one per command, each owning its own `validate_<cmd>_args()` + `cmd_<name>()`). `skill/scripts/` holds only the two real entry points, `jira.sh` + `md-to-adf.sh`; every sourced-only unit lives in `skill/lib/`, matching the scripts=invokable / lib=sourced-only convention the sibling families follow.

Honest note carried from the design: **total line count barely dropped** (5,376 → ~5,530 across 45 files). Only ~130 lines were genuine duplication; the rest of the apparent "savings" is offset by new per-file headers and wrapper boilerplate. The win is navigability and per-command ownership, not size — say this plainly if anyone asks "did this shrink the codebase."

A **mandatory variable-collision checker** was built at `tests/check-variable-collisions.sh` (POSIX sh has no `local`, so all 45 files still share one flat variable namespace — splitting into many files makes a collision *harder* to eyeball, not easier). It found and fixed one real violation: `url` was shared across `jira_curl`/`resolve_account_id`/`cmd_search`/`cmd_view` — all reachable in one call chain. Three call sites were renamed (`rai_url`, `search_url`, `view_url`); `jira_curl`'s own `url` parameter was correctly left alone (it's the shared transport, not a caller sharing a name across chains).

**Known, accepted compromise — do not "fix" this without a real conversation first:** `lib/` is not a strict lower layer. `lib/issue-set.sh` calls `cmd_search` (a command function). Several lib functions read `OPT_*` globals directly rather than taking parameters. This was a deliberate call: true layering would be a rewrite, not a refactor, and would have broken the behavior-parity proof this whole effort leans on. It's documented in the affected files' headers. If a future session wants real layering, that's a separate, larger, explicitly-scoped effort — not a lens-review fix.

### 1b. GH + GL issues (`project-management/agents/project-manager/skills/procedure-{gh,glab}-issues/`)
7 command files per family, previously duplicating diagnostics/validators/preconditions/list-handling. gh: 1,844 → ~1,476 script lines + 4 new lib files (`pm-diag.sh`, `pm-validate.sh`, `pm-gh-preconditions.sh`, `pm-lists.sh`). glab: 3,373 → ~2,475 script lines + 7 new lib files (adds `pm-glab-env.sh`, `pm-glab-preconditions.sh`, `pm-glab-labels.sh`, `pm-glab-url.sh`).

Two **real, pre-existing behavioral inconsistencies preserved on purpose** (do not silently "fix" either without a separate, explicit decision — both are pinned by tests):
- `create-issue.sh --assignee`/`--project` do NOT comma-split; `update-issue.sh --add-assignee` DOES. Inconsistent within gh itself, cause unclear.
- gh's `is_valid_repo_slug` accepts `/gp` and `./p` that GitLab's `is_valid_gitlab_project_path` rejects. Not a traversal risk (no `..`), just a looseness gap between the two validators.

The two GitLab URL-extractor functions (`extract_issue_url_candidates` vs `extract_note_url_candidates`) were kept as two separate functions (they differ by exactly one regex anchor, `#note_<id>`) rather than unified behind a mode flag — this codebase's convention explicitly rejects flag-argument-switching helpers.

**A genuinely new discovery, beyond the original design brief:** while re-verifying against real GitLab behavior, the developer found GitLab has migrated issue URLs to a `/-/work_items/<iid>` path (older docs/deployments may still say `/-/issues/<iid>`); both extractor regexes now accept `(issues|work_items)`. This is a real robustness improvement, not scope creep — verify it's still correct if GitLab changes this again.

**One fix applied post-review (by the orchestrator directly, not a dispatched reviewer):** all 14 command files' lib-sourcing was originally unguarded (a missing/broken `lib/` file produced a raw `.: not found` instead of a clear error). Added a readability-guard loop before sourcing, matching the fix already applied to the PR/MR family (see §1c) — for consistency across all 3 families now.

### 1c. GH-PR + GL-MR (`software-development/agents/specialists/git-operator/skills/procedure-{gh-pr,glab-mr}/`)
3 command files per family. gh-pr: 855 → ~661 script lines + 1 new lib file (`gh-pr-common.sh`). glab-mr: 1,645 → ~1,194 script lines + 2 new lib files (`glab-mr-common.sh`, `glab-mr-output.sh` — split because the output-parsing helpers have their own independent security-fix history that gh-pr has no equivalent for).

**The one genuine rewrite in this whole effort:** gh-pr's 7 `add_*` functions (reviewers/labels/assignees/add-label/remove-label/add-reviewer/remove-reviewer) were replaced with 7 call sites to one new `accumulate()` helper. This was gated on 33 new characterization tests landing first (proven green against the *old* code), then **mutation-tested in both directions**: 4 seeded regressions in the old `add_*` functions produced 10 test failures (proving the new tests actually discriminate); re-mutating `accumulate()` itself produced 12 failures. Round-1 review confirmed this independently rather than trusting the claim.

Round-1 review found 2 LOW findings (same unguarded-lib-source issue as above, plus a test-harness preflight that couldn't fire because an earlier `cd` aborted first) — both fixed and re-verified in the same round.

---

## 2. A critical bug the automation suites structurally could not catch

**This is the single most important thing in this handoff.** None of the 14 shell-script test harnesses exercise the hub's deployment/discovery mechanism — they all test the scripts as standalone files. Only a **live deployment through the real hub** surfaced this:

`deploy/hub/lib/hub-discovery.sh:284` (`hub_disc_pm()`) had a hardcoded `-maxdepth 2` when walking Project Management's own-agent `skills/` subtree to find `SKILL.md` files. Under the new `skill/` subfolder convention, `SKILL.md` sits at depth 3 from that anchor, not depth 2 — so `find` never reached it. Result: `procedure-jira`, `procedure-gh-issues`, and `procedure-glab-issues` were **completely invisible to the hub** — not merely misclassified, absent from install entirely (confirmed via a real `--target` scratch install: only 78/83 correct items landed, all 3 PM skills missing). A second, compounding bug at line 295 fed the tracker classifier (`hub_pm_tracker_of`) the literal string `"skill"` instead of the real skill name, which would have misclassified them even if depth were fixed.

Software Development's equivalent specialist-skill discovery (line 195) has **no** maxdepth restriction at all, which is exactly why `procedure-gh-pr`/`procedure-glab-mr` worked fine and this bug stayed hidden until a live PM-domain install was actually run.

**Both are fixed** (in `deploy/hub/lib/hub-discovery.sh`, currently uncommitted alongside everything else): the maxdepth is now 3, with a comment explaining the dual-layout reality (some PM skills still use the old flat layout; some now use `skill/`); the classifier now unwinds the reserved `"skill"` basename to its parent directory's name before classifying.

**Re-verified live, end to end**, in a scratch `--target`: fresh install shows all 5 decomposed skills correctly (78→83 items, right cross-domain auth dependencies wired), all 5 invoke cleanly through their *actual deployed symlinks* (not just from the repo checkout), `crucible-hub doctor` shows GitHub/GitLab/Jira all green, `uninstall`'s resolution plan (Kept/Cascade) resolves correctly through the same fixed discovery path.

**`accounts/` has the identical `-maxdepth 2` pattern at `hub-discovery.sh:364`, untouched and unverified in this pass** — harmless today because no `accounts/` skill uses the `skill/` convention yet, but it will break the exact same way the day one does. Flag this loudly if anyone migrates `procedure-github-auth`/`procedure-gitlab-auth` to the new layout.

---

## 3. What still needs a second, independent pass — and why

Everything above was verified for **behavior parity** (does the new code do exactly what the old code did) extremely rigorously — byte-identical `diff`s, mutation testing, live deployment smoke tests. What it was **not** given was a from-scratch, adversarial `lens-clean-code-reviewer` / `lens-consistency-reviewer` / `lens-security-reviewer` / `lens-test-quality-reviewer` pass asking the more open-ended question the user actually cares about: **is each new file genuinely well-designed — good SRP, no gratuitous complexity, idiomatic, consistent with the rest of the framework — or did the decomposition mechanically satisfy the design doc while leaving something a fresh set of eyes would flag?**

Two reasons this matters, stated honestly:
1. **The 200-subagent spawn cap was hit mid-effort.** GH-PR/GL-MR got one real dispatched `shell-script-reviewer` round. Jira and GH+GL-issues got reviewed by the *same orchestrating session that designed and tracked the whole effort* — better than nothing, but not the independent, blind-to-the-implementation-agent's-own-framing review the process normally calls for.
2. **No dedicated design-quality lens ever ran.** The "lens swarm" step in this session's own final report was, by its own disclosure, a direct security/consistency grep sweep done by the orchestrator, not a dispatched `lens-clean-code-reviewer` et al. It found nothing dangerous, but it wasn't the real thing.

### What the next session should do

**Run a genuine `flow-review`-shaped lens pass, from a fresh session (so it isn't reviewing its own design work), scoped as a FULL AUDIT of these 5 skill directories** (not a diff — the "diff" here is nearly the whole file, so a full-file read is more honest than a diff-mode review):
- `project-management/agents/project-manager/skills/procedure-jira/skill/`
- `project-management/agents/project-manager/skills/procedure-gh-issues/skill/`
- `project-management/agents/project-manager/skills/procedure-glab-issues/skill/`
- `software-development/agents/specialists/git-operator/skills/procedure-gh-pr/skill/`
- `software-development/agents/specialists/git-operator/skills/procedure-glab-mr/skill/`

Dispatch, in parallel, against each family (or all 5 at once if token budget allows — these are read-only reviewers):
- **`lens-clean-code-reviewer`** — the actual ask: is every new file's SRP real (not just asserted in a header comment)? Are the `lib/` boundaries the RIGHT boundaries, or did the mechanical extraction create an awkward one anywhere (e.g. `procedure-glab-issues/skill/scripts/find-duplicate.sh` sources `pm-glab-labels.sh` for one function, `pm_strip_jq_quotes`, and pulls in two unused pagination constants it doesn't need — flagged as harmless by this session, but a fresh lens should form its own opinion)? Any dead code left behind by the extraction? Any file that's a clean split on paper but reads worse than the monolith it replaced?
- **`lens-consistency-reviewer`** — are the 5 families internally consistent with each other now (naming: `pm-*.sh` vs `gh-pr-common.sh`/`glab-mr-*.sh` vs Jira's plain names — is that variance justified or accidental)? Does the `skill/` convention's documentation (each `SKILL.md`) accurately describe the new structure? Full audit mode, since a diff-only review would miss "is this file's *placement* right," which is exactly what a full audit is for.
- **`lens-security-reviewer`** — this session ran a direct grep sweep (`eval`, `curl -k`, hardcoded secrets, unquoted `rm`/`mv`) and independently re-verified the security-critical regex/allow-list extractions byte-for-byte, but a dedicated security lens brings threat-modeling a grep sweep can't: trust-boundary reasoning across the new `lib/` seams, whether the credential/host-pinning invariants (Jira's `sitegate.sh`, the two path validators, the SEC-002 URL-anchor regex) are *provably* unreachable from an untrusted-input path, not just textually unchanged.
- **`lens-test-quality-reviewer`** — every new/changed test was written to prove behavior parity (characterization tests, mutation tests). Nobody has yet asked "are these tests otherwise GOOD tests" by this framework's own `standard-testing` rubric — readable, not over-mocked, actually documentation of behavior, not just parity-proof scaffolding.

If any of the four finds gating (MEDIUM+) issues: re-enter `flow-implementation` with the matching family's `shell-script-developer` + `shell-script-reviewer`, capped at 3 rounds, exactly as this session did. Given the amount of independent verification already done, expect this pass to mostly confirm — but "mostly" is not "certainly," and that gap is exactly why the user asked for it.

---

## 4. How to run the tests

**Per-family, standalone** (each is self-contained, POSIX `sh`, no network calls — everything is stubbed):
```sh
sh project-management/agents/project-manager/skills/procedure-jira/tests/run-tests.sh          # 155 checks
sh project-management/agents/project-manager/skills/procedure-jira/tests/run-engine-tests.sh   # 859 checks
sh project-management/agents/project-manager/skills/procedure-jira/tests/run-write-tests.sh     # 364 checks
sh project-management/agents/project-manager/skills/procedure-jira/tests/run-rig-tests.sh       # 141 checks
sh project-management/agents/project-manager/skills/procedure-jira/tests/check-variable-collisions.sh   # the mandatory namespace-collision gate

sh project-management/agents/project-manager/skills/procedure-gh-issues/tests/run-tests.sh      # 341 checks
sh project-management/agents/project-manager/skills/procedure-glab-issues/tests/run-tests.sh    # 652 checks

sh software-development/agents/specialists/git-operator/skills/procedure-gh-pr/tests/run-tests.sh    # 150 checks
sh software-development/agents/specialists/git-operator/skills/procedure-glab-mr/tests/run-tests.sh  # 310 checks
```
Run every one under **both** `sh` and `dash` (all claim dash-compatibility; verify it, don't assume it):
```sh
for f in <one of the run-tests.sh paths above>; do sh "$f" && dash "$f"; done
```

**Repo-wide regression sweep** (confirms this refactor didn't break anything outside its own scope):
```sh
for f in $(find . -name 'run-tests.sh' -not -path './.git/*'); do
  echo "=== $f ==="; sh "$f" 2>&1 | tail -3
done
```
As of this handoff: **all 14 pass, 0 failures.** (One of them, `flow-spec`'s, takes long enough that a naive 2-minute Bash-tool timeout will cut it off mid-run — that's a tooling artifact, not a hang; give it more time or run it standalone.)

**`shellcheck`** (must stay clean; every suppression in this codebase carries a reason comment — match that style if you add one):
```sh
shellcheck -x -s sh <skill>/skill/scripts/*.sh <skill>/skill/lib/*.sh
```

## 5. How to verify against live sources

Everything above is stubbed — no real `gh`, `glab`, or Jira API call happens in any test. Two live-verification layers exist; **do the deployment one before the API one**, since the deployment bug in §2 would have made the API layer irrelevant (the scripts wouldn't have been reachable at all):

**Layer 1 — deployment (do this first, it's what caught §2's bug):**
```sh
rm -rf /tmp/crucible-check
./deploy/hub/crucible-hub --target /tmp/crucible-check install --all --apply
ls /tmp/crucible-check/skills/ | grep -iE 'jira|gh-issues|glab-issues|gh-pr|glab-mr'   # expect all 5
./deploy/hub/crucible-hub --target /tmp/crucible-check doctor                          # expect GitHub/GitLab/Jira all green (if you have real credentials configured)

# Invoke through the REAL deployed symlink, not the repo checkout directly:
sh /tmp/crucible-check/skills/procedure-jira/scripts/jira.sh -h
sh /tmp/crucible-check/skills/procedure-gh-issues/scripts/comment.sh -h
sh /tmp/crucible-check/skills/procedure-glab-issues/scripts/find-duplicate.sh -h
sh /tmp/crucible-check/skills/procedure-gh-pr/scripts/find-pr.sh -h
sh /tmp/crucible-check/skills/procedure-glab-mr/scripts/find-mr.sh -h
# all should exit 0 and print usage

./deploy/hub/crucible-hub --target /tmp/crucible-check uninstall --all   # dry-run preview only, confirms Kept/Cascade resolves; do NOT pass --confirm=UNINSTALL against anything you care about
rm -rf /tmp/crucible-check
```

**Layer 2 — real API calls (only if you have live, low-stakes credentials — a scratch/test repo and a throwaway/sandbox Jira project, never a production tracker):**
- `procedure-github-auth`/`procedure-gitlab-auth`/`procedure-jira-auth`'s own auth-status scripts first, to confirm a real, confirmed account.
- Then a genuinely read-only command per family first: `find-duplicate.sh` (gh/glab issues), `find-pr.sh`/`find-mr.sh` (PR/MR), `jira.sh view <a real ticket key>`. These touch the real API but write nothing.
- Only after read paths are confirmed working, consider a real write against a scratch/sandbox project — e.g. `create-issue.sh` against a throwaway repo, `jira.sh create` against a sandbox Jira project. **Never do this against a real tracker or repo that matters.**
- This is the layer that would catch anything the stubs can't model: real `gh`/`glab`/`jira` CLI output format drift, real network/TLS behavior, real auth-flow edge cases. Nothing in this session's work specifically suggests this layer will find something — the stubs are unusually thorough — but it has never been run for these 5 skills' NEW file layout, only the old one.

## 6. Deferred items — explicit follow-ups, not silently dropped

1. **20 files repo-wide share this exact diagnostic/precondition duplication, out of scope for this pass**: `procedure-jira-auth`, `procedure-git-ops`, `procedure-git-identity`, `accounts/procedure-github-auth`, `accounts/procedure-gitlab-auth`. If the `skill/`+`lib/` convention is judged a success after the second lens pass, these are the natural next candidates — but that's a new, separately-scoped decision, not an automatic continuation.
2. **`procedure-gh-issues`' `--assignee`/`--project` vs `--add-assignee` comma-split inconsistency** — real, preserved, pinned by tests, needs a human call on whether to unify (and if so, which behavior wins).
3. **`accounts/`'s discovery has the same latent `-maxdepth 2` bug** as §2, currently dormant. Fix it proactively or at minimum leave this warning in place if `accounts/` skills are ever migrated to the `skill/` convention.
4. **This branch itself**: once the second lens pass (§3) is clean, the sequencing that landed the previous branch applies again — `git-operator` plans an accurate PR description (do not trust a first-draft summary; independently verify commit/diff counts against `git log`/`git diff --stat` the way this session caught its own undercount last time), expose the full body, get explicit consent, open the PR, merge into `main`. None of that has happened yet for this branch.

---

## 7. Quick-reference: files touched this session

Full list is `git status --porcelain` on this branch. Grouped:
- **Jira**: 45 files under `procedure-jira/skill/` (1 dispatcher, 17 lib, 26 cmd, 1 moved `md-to-adf.sh`, 1 moved `SKILL.md`) + 4 touched test harnesses + 1 new `check-variable-collisions.sh`.
- **GH issues**: 7 slimmed command files + 4 new lib files + 1 moved `SKILL.md` + 1 touched harness.
- **GL issues**: 7 slimmed command files + 7 new lib files + 1 moved `SKILL.md` + 1 touched harness.
- **GH PR**: 3 slimmed command files + 1 new lib file + 1 moved `SKILL.md` + 1 touched harness.
- **GL MR**: 3 slimmed command files + 2 new lib files + 1 moved `SKILL.md` + 1 touched harness.
- **Hub**: 1 file, `deploy/hub/lib/hub-discovery.sh` (the §2 fix — this is the one change outside the 5 skills' own directories).
