# Agent-run parked map

**Date:** 2026-11-22

**Purpose:** a durable map of the old tree's agent-related and other non-tree parts, parked when the git toolbelt (`git-commit`, `git-worktree`, `git-mount`, `git-push`) was ported, so nothing slips. It also lists the gaps found in section 4.3 of `git-worktree-design.md`.

**Swept:** every tracked file under `rewrite/domains/software-development/` (205 files, from `git ls-files`), plus the untracked `flow-code-review/` scripts and the two untracked seat-run rule files. In `rewrite/framework/`, only the files that handle seats, worktrees, commits, pushes or agent stops are listed. The standard and tech plugins were checked. Only `testing/references/test.md` touches the topic; the others say "commit" only for database transactions.

**Hook wiring:** no `settings.json` or `hooks.json` is tracked. The hook entries are checked and printed by `validate-dependencies.sh` and listed for removal in `turn-off-and-uninstall.md` (bucket C):
- `PreToolUse` on `Agent`: `prepare-agent-prompt.sh`.
- `PostToolUse` on `Agent`: `seat-bind-hook.sh`.
- `PreToolUse` on `Write|Edit|MultiEdit|NotebookEdit`: `pre-tool-hook.sh`.
- `SubagentStop`: `report-commit-hook.sh`, plus `block-relay-hook.sh` (async).
- `PreToolUse` on `Bash`: `events-guard-hook.sh`.
- `PreToolUse` and `PostToolUse` on `AskUserQuestion`: the gate hooks.

**Reading marks:**
- *opened*: header and usage read, plus targeted reads where coupling mattered.
- *listed*: only the first line read.
- *untracked*: on disk, not in git, still in progress.

## A. Git-tree mechanics

| File | Status | New home, or why not |
|---|---|---|
| `rewrite/domains/software-development/core/main-thread/procedures/procedure-git-worktree/SKILL.md` | covered | A thin `SKILL.md` per component |
| `…/procedure-git-worktree/references/chains.md` (listed) | covered | Gone. When to offer a sync goes into `git-worktree/SKILL.md`. |
| `…/procedure-git-worktree/references/move-and-catch-up.md` (listed) | covered | Gone, into `git-worktree/SKILL.md` |
| `…/procedure-git-worktree/references/mount.md` (listed) | covered | Gone, into `git-mount/SKILL.md` |
| `…/procedure-git-worktree/references/push.md` (listed) | covered | Gone, into `git-push/SKILL.md` |
| `…/procedure-git-worktree/references/sync-question.json` (listed) | covered | Gone: core's gate |
| `…/procedure-git-worktree/references/remount-question.json` (listed) | covered | Gone: core's gate. The remount offer becomes main's own call from `mount-status.sh` facts. |
| `…/procedure-git-worktree/scripts/base/seat-base.sh` | **mapped wrongly (partly)** | 4.3 says "gone: facts + `--from`". Two of its jobs have no home: a base made by merging **several** idle trees' tips (`--on S --on S`, through `tips-merge.sh`), and its `unmerged` list (idle trees whose tip is not in the checkout's HEAD). Proposed: `worktree-cut.sh --from worktrees:A,B` (it runs `commits-merge.sh`), and a per-tree "tip in HEAD" flag in `worktree-facts.sh`. |
| `…/procedure-git-worktree/scripts/cards/cards-lib.sh` | covered | Gone. Its "unsigned" line becomes `signed: false` in the scripts' JSON. |
| `…/procedure-git-worktree/scripts/commit/commit-message.sh` | covered | `git-commit/commit-message.sh`, generic input |
| `…/procedure-git-worktree/scripts/commit/commit-message.jq` | covered | With `commit-message.sh`. Its hard-coded kinds go (Coupling notes). |
| `…/procedure-git-worktree/scripts/commit/commit.sh` | covered | `git-commit/commit-tree.sh` |
| `…/procedure-git-worktree/scripts/merge/tips-merge.sh` | covered | `git-commit/commits-merge.sh` |
| `…/procedure-git-worktree/scripts/merge/catch-up.sh` | covered | `git-worktree/worktree-catch-up.sh`. The builder-role check, the idle check and the write-scope cancel go to agent-run. |
| `…/procedure-git-worktree/scripts/merge/chain.sh` | covered | `git-worktree/worktree-chain.sh`, from events |
| `…/procedure-git-worktree/scripts/merge/chain.jq` | covered | With `worktree-chain.sh`. Its `base_seats` is a list (see `seat-base.sh`). |
| `…/procedure-git-worktree/scripts/merge/chain-sync.sh` | covered | `git-worktree/worktree-chain-sync.sh` |
| `…/procedure-git-worktree/scripts/mount/mount.sh` | covered | `git-mount/mount-apply.sh`. Its "idle builder seats only" check goes to main or agent-run. |
| `…/procedure-git-worktree/scripts/mount/mount-lib.sh` | covered | `git-mount/lib/mount.sh`. The record's `seats[{seat, worktree, seat_commit}]` becomes tree names. |
| `…/procedure-git-worktree/scripts/mount/unmount.sh` | **covered, one miss** | `git-mount/mount-undo.sh`. It also loads `seats.jq` and prints `seats`; 4.3 strips the seat pattern only in `mount-lib`. |
| `…/procedure-git-worktree/scripts/mount/mount-status.sh` | covered | `git-mount/mount-status.sh`. "A seat moved since" is read from `worktree.*` events. |
| `…/procedure-git-worktree/scripts/mount/effort-commits.sh` | covered | `git-mount/effort-commits.sh`. Its identity comes from `identity-get.sh`, not `settings.sh`. |
| `…/procedure-git-worktree/scripts/push/push.sh` | covered | `git-push/push-tree.sh`. `seat.pushed` becomes `push.made`, and the lease follows `worktree.moved`. |
| `…/procedure-git-worktree/scripts/seats/seat-move.sh` | covered | Gone. The git part is `worktree-move.sh`; rolling back when the seat bookkeeping refuses goes with agent-run. |
| `…/procedure-git-worktree/scripts/seats/seat-open.sh` | covered | Gone: `worktree-cut.sh` |
| `…/procedure-git-worktree/scripts/worktree/dirty-check.sh` | covered | Gone. Its counts are in `worktree-facts.sh`; its "where do builders start" question is main's. |
| `…/procedure-git-worktree/scripts/worktree/snapshot.sh` | covered | `git-worktree/worktree-snapshot.sh` |
| `…/procedure-git-worktree/scripts/worktree/uncommitted.jq` | covered | `git-worktree/scripts/lib/uncommitted.jq` |
| `…/procedure-git-worktree/scripts/worktree/worktree-create.sh` | covered | The git part of `worktree-cut.sh` |
| `…/procedure-git-worktree/scripts/worktree/worktree-move.sh` | covered | `git-worktree/worktree-move.sh` |
| `…/procedure-git-worktree/scripts/worktree/worktree-setup.sh` | covered | `git-worktree/worktree-setup.sh` |
| `…/procedure-git-worktree/scripts/worktree/worktree-setup.jq` | covered | Same |
| `…/procedure-git-worktree/scripts/worktree/worktree-setup.json` | covered | Same. Secret-holding entries become opt-in. |
| `…/procedure-git-worktree/views/caught-up.jq` (listed) | covered | Gone: JSON result, main's card |
| `…/procedure-git-worktree/views/chain-synced.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/common.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/conflict.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/lines.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/mount-status.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/mounted.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/remount-offer.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/seat-base.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/seat-moved.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/sync-offer.jq` (listed) | covered | Gone |
| `…/procedure-git-worktree/views/unmounted.jq` (listed) | covered | Gone |
| `rewrite/domains/software-development/core/main-thread/procedures/procedure-git-setup/SKILL.md` | **MISSING from 4.3 (identity part already ported)** | The identity is `git-identity/SKILL.md`. The auto-push question has no home: `git-push`, as the "later setting". |
| `…/procedure-git-setup/scripts/identity-candidates.sh` | ported outside 4.3 | `git-identity/scripts/identity-list.sh` |
| `…/procedure-git-setup/scripts/list-identities.sh` | ported outside 4.3 | `git-identity/scripts/identity-list.sh` and `lib/git-identity.sh` |
| `…/procedure-git-setup/scripts/resolve-identity.sh` | ported outside 4.3 | `git-identity/scripts/identity-check.sh` |
| `…/procedure-git-setup/scripts/render-identity.sh` | ported outside 4.3 | `git-identity/scripts/identity-card.sh` |
| `…/procedure-git-setup/scripts/render-git-setup.sh` | **MISSING (half)** | The identity tab is `identity-card.sh`. The Auto-push tab goes to `git-push` (setting). |
| `…/procedure-git-setup/scripts/origin-lib.sh` | **MISSING** | The "does the repo have the remote an effort pushes to" check: `git-push/push-tree.sh` pre-check, and the auto-push setting |
| `…/procedure-git-setup/scripts/settings.sh` | **MISSING (half)** | Identity: `identity.set` plus `identity-get.sh`. The `auto_push` field goes to `git-push` (setting). Every old tree script that read the identity here now reads `identity-get.sh`. |
| `…/procedure-git-setup/scripts/settings.jq` | **MISSING (half)** | As `settings.sh` |
| `…/procedure-git-setup/views/git-setup.jq` | ported outside 4.3 | `identity-card.sh`; its auto-push part as above |
| `…/procedure-git-setup/views/identity.jq` | ported outside 4.3 | `identity-card.sh` |
| `…/procedure-git-setup/views/lines.jq` | ported outside 4.3 | Gone: the core gate's lines |
| `rewrite/framework/core/engine/crucible/SKILL.md` | **MISSING** | It defines `worktrees/` inside the effort folder, which design §3 keeps. `prune` deletes the tree folders but leaves their git registrations, `crucible/` branches and kept refs in the repository. Nothing in 4.3 cleans those up after a prune. Proposed: prune refuses while `git-worktree/open-work.sh` lists live trees, or prune runs `worktree-drop.sh` per tree, which already works on a deleted folder. Split: `drafts/agents/<seat>/` and `mutation/` go to bucket B. |

`…/` stands for `rewrite/domains/software-development/core/main-thread/procedures/`.

## B. Agent-run

**Open question for the agent-run design:** what may a dispatched agent read? Core's `deny-internals-read.sh` hook skips any call that carries an `agent_id`, so today an agent can read framework internals that main can't. Decide it with the agent-run design; don't change it in the hook beforehand.

| File | Its one job | Git component it would call | Seat/agent coupling |
|---|---|---|---|
| `rewrite/domains/software-development/core/main-thread/procedures/procedure-git-worktree/scripts/commit/commit-input.sh` | Builds the commit-message input from a seat's report: the kind from its role, the iteration from `iteration.sh`, the text from the report, and the trailers. **4.3 calls it "gone"; it is agent-run's adapter.** | Produces input for `git-commit/commit-message.sh` | role, seat, iteration, report draft |
| `rewrite/domains/software-development/core/main-thread/procedures/procedure-seat-run/SKILL.md` | Launches approved dispatches, acts on each result, sends changes and new work to a seat, answers report asks, resumes, closes | All four, through its hooks and steps | The whole seat model |
| `…/procedure-seat-run/references/changes.md` | Sends the human's change to the same warm agent; worktree check for a tester; the pair hold | `git-worktree` facts (uncommitted check) | seat status, tester/build pair, SendMessage |
| `…/procedure-seat-run/references/human-asks.md` | Answers asks about a shown report or its commit | none (reads events) | report events, seat status |
| `…/procedure-seat-run/references/new-work.md` | New work on a seat: hot agent or fresh agent (handover) | `git-worktree/worktree-move.sh` (caller moves first) | seats.sh task/handover |
| `…/procedure-seat-run/references/resume.md` | Takes each seat back up after a break, by status | none directly | seat list, iteration, todo items |
| `…/procedure-seat-run/scripts/hooks/report-commit-hook.sh` | SubagentStop: finds the agent's seat, prunes and checks its report, blocks on misfit (max N), commits the tree, auto-pushes, records `build.committed` / `test.committed` / `test-plan.made`, recovers a run that died; reviewer stops go to the review scripts | `git-commit/commit-message.sh` and `commit-tree.sh`; `git-push/push-tree.sh` when auto-push is on; reads git status, `MERGE_HEAD` and `diff --check` for leftover conflict markers, and `git log` by the `Agent-Seat`/`Iteration` trailers for recovery | agent_id→seat, roles, iteration, draft rename, hook time budget |
| `…/procedure-seat-run/scripts/hooks/block-relay-hook.sh` | Async SubagentStop: wakes main with the exact block line to relay to an agent that already handed back, or with a give-up; for a reviewer stop, wakes main with the round's next step | none | stop.blocked/gave-up events, seat status, review-status.sh |
| `…/procedure-seat-run/scripts/hooks/seat-bind-hook.sh` | PostToolUse on Agent: binds the launched agent_id to its seat (`seat.bound`) | none | dispatch.allowed / dispatch.made, seats.sh bind |
| `…/procedure-seat-run/scripts/hooks/pre-tool-hook.sh` | PreToolUse on writes: runs each pre-tool rule; first deny wins; faults never hold an agent | none | agent_type rules |
| `…/procedure-seat-run/scripts/hooks/rules/lib/write-scope-rule.sh` (untracked) | Shared body of the write-scope rules: deny a write outside the role's scope, path taken relative to its worktree | none (`git rev-parse --show-toplevel` only) | role, agent_type, `write-scope.jq` |
| `…/procedure-seat-run/scripts/hooks/rules/pre-tool/builder-write-scope.sh` | Denies a builder's write to a test path | none | code-builder role |
| `…/procedure-seat-run/scripts/hooks/rules/pre-tool/tester-write-scope.sh` | Denies a tester's write outside test paths | none | code-tester role |
| `…/procedure-seat-run/scripts/hooks/rules/pre-tool/reviewer-write-scope.sh` (untracked) | Denies any reviewer write inside a worktree | none | code-reviewer role |
| `…/procedure-seat-run/scripts/hooks/rules/stop/builder-write-scope.sh` | At stop: names test paths a builder changed via shell (git status), merge-brought paths left out | reads git status / `MERGE_HEAD` (could use `git-worktree` facts) | builder role |
| `…/procedure-seat-run/scripts/hooks/rules/stop/tester-write-scope.sh` | At stop: names production paths a tester changed | same | tester role |
| `…/procedure-seat-run/scripts/hooks/rules/stop/mutation-copy.sh` | Blocks a tester's stop while its mutation copy exists | none | tester, drafts/agents/<seat>/mutation |
| `…/procedure-seat-run/scripts/mutation/mutation-copy.sh` | Opens/removes a tester's throwaway copy of its build tree (no `.git`) | none | tester seat, build seat's worktree |
| `…/procedure-seat-run/scripts/render-pair-hold.sh` | Gate: resume the agent that left uncommitted work in a shared tree, or discard it | `git-worktree` facts; discard would need a tree reset (no 4.3 script discards uncommitted work) | builder/tester pair sharing one tree |
| `…/procedure-seat-run/scripts/seats/seats.sh` | The seat list as `seat.*` events: choose, join, opened, drop, bind, status, handover, move, task, get, find, busy, list | Reads `worktree.cut` instead of holding repo/base/worktree itself | everything: roles, status, build_seat, base_seats, agent_id |
| `…/procedure-seat-run/scripts/seats/seats.jq` | Seat-list rules and changes, next seat name | none | as above. Split: `seats_next_name` goes to bucket C. |
| `…/procedure-seat-run/scripts/seats/seats-events.jq` | Replays `seat.*` events into the list | none | as above |
| `…/procedure-seat-run/scripts/seats/seats-guard.jq` | Refuses a seat event that no longer applies, under the events lock | none | as above |
| `…/procedure-seat-run/scripts/seats/iteration.sh` | A seat's iteration (1 + its build commits since base, counted in `git log`), report path, last report and whether it is done | reads `git log` by trailer; better from agent-run's own commit events | builder/tester/reviewer iteration rules |
| `…/procedure-seat-run/scripts/seats/gate-answered.sh` | Whether the gate after a seat's newest result is answered | none | seat, gate labels |
| `…/procedure-seat-run/scripts/seats/write-scope.jq` | Which paths a role may write (test paths vs. production) | none. Used by old `catch-up.sh`, which 4.3 strips. | builder/tester/reviewer |
| `…/procedure-seat-run/views/lines.jq` | Seat-run fixed lines (gave up, pair leftovers, not committed…) | none | seat |
| `…/procedure-seat-run/views/pair-hold.jq` | Pair-hold gate layout | none | pair |
| `rewrite/domains/software-development/core/main-thread/flows/flow-code-review/scripts/review-request.sh` (untracked) | The stop hook's reviewer step: prints the seat's newest request and writes what the review checker needs | none | reviewer seat, request |
| `rewrite/domains/software-development/core/agents/code-builder/code-builder.md` | The builder agent: works in one tree, one git write (`git restore` of a test path a block names), resolves a merge left in its tree | none (agent never runs git writes) | WORKTREE/REPORT message, stop blocks |
| `rewrite/domains/software-development/core/agents/code-tester/code-tester.md` | The tester agent: plans and writes tests in its build seat's tree, mutation copy | none | build seat's tree, plan gate |
| `rewrite/domains/software-development/core/agents/code-reviewer/code-reviewer.md` | The reviewer agent: reviews one diff through one lens; read-only git log/blame | none | DIFF file, REPO ROOT, request |
| `rewrite/domains/software-development/core/agents/skills/standard-code-seat-agent/SKILL.md` | Shared seat conduct: absolute paths, write scope, never touch git state, read-only git forms, stop reply | none | the agent-in-a-tree contract |
| `rewrite/domains/software-development/core/agents/code-builder/skills/standard-code-build-report/SKILL.md` | The build report contract; the stop hook checks, commits, records | `git-commit` via the hook | iteration, build.committed |
| `…/standard-code-build-report/references/report-iteration.json` | Example report | none | none |
| `…/standard-code-build-report/scripts/build-report-check.sh` | Checks a build or test report and its `path:line` locations in the tree | none | role kind |
| `…/standard-code-build-report/scripts/build-report-check.jq` | The report's keys and checks | none | builder/tester kinds |
| `…/standard-code-build-report/scripts/build-report-prune.sh` | Drops empty keys before the check | none | none |
| `…/standard-code-build-report/scripts/report-limits.sh` | Prints/places the report caps in SKILL.md | none | none |
| `…/standard-code-build-report/scripts/card.sh` | The human's card for a `build.committed` or `test.committed` event: counts, gates, files from the commit's diff, the signature, faults | reads the commit diff and signature (a `git-commit` read, or the commit event's `signed`) | role from the seat name, dispatch plugins |
| `…/standard-code-build-report/views/card.jq` | Card layout | none | none |
| `rewrite/domains/software-development/core/agents/code-tester/skills/standard-code-test-report/SKILL.md` | Test plan and test report contract | `git-commit` via the hook (report only) | test-plan.made / test.committed |
| `…/standard-code-test-report/references/test-plan.json` | Example plan | none | none |
| `…/standard-code-test-report/scripts/test-plan-check.sh` | Checks a test plan and its locations | none | tester |
| `…/standard-code-test-report/scripts/test-plan-check.jq` | Plan checks | none | tester |
| `…/standard-code-test-report/scripts/plan-draft.jq` | Draft numbering after a commit or closed plan | none | seat, gate labels |
| `…/standard-code-test-report/scripts/plan-card.sh` | Card for a `test-plan.made` event | none | seat, dispatch |
| `…/standard-code-test-report/views/plan-card.jq` | Plan card layout | none | none |
| `rewrite/domains/software-development/core/agents/code-reviewer/skills/standard-code-review-report/SKILL.md` | Review report contract | none | review round |
| `…/standard-code-review-report/scripts/report.sh` | Checks a reviewer draft against its request, the diff, locations and branch in the tree | reads the tree (a `git-worktree` read) | reviewer seat, request |
| `…/standard-code-review-report/scripts/report.jq` (untracked) | The draft's checks | none | request keys/threads |
| `rewrite/framework/core/engine/crucible/scripts/events.sh` | Core event writer. Split, agent-run part: `find-agent` (agent_id→effort and seat from `seat.bound`) and the after-end types (`build.committed`, `test.committed`, `seat.pushed`). | Its after-end list must name `push.made` | `seat.bound`, seat names |
| `rewrite/domains/software-development/core/plugins/standards/testing/references/test.md` | Tester plugin text: break code only in the throwaway copy, never git stash/checkout/restore in the real tree | none | mutation copy |

`…/` stands for `rewrite/domains/software-development/core/main-thread/procedures/` (seat-run rows) or `rewrite/domains/software-development/core/agents/<agent>/skills/` (report rows).

## C. Dispatch / sender

| File | Note |
|---|---|
| `rewrite/domains/software-development/core/main-thread/procedures/procedure-seat-run/scripts/seats/seat-name.sh` | Next free seat name for a role. In the new design, main names trees and the sender names jobs. |
| `rewrite/domains/software-development/core/main-thread/flows/flow-code-agent-dispatch/SKILL.md` | Flow from tasks to checked dispatches |
| `…/flow-code-agent-dispatch/references/boundary-map.md` | Which plugin owns a shared concern |
| `…/flow-code-agent-dispatch/references/denials-and-replans.md` | Hook denials and re-plans |
| `…/flow-code-agent-dispatch/references/install-failures.md` | Dependency check failures |
| `…/flow-code-agent-dispatch/references/plan-failures.md` | Plan step failures |
| `…/flow-code-agent-dispatch/references/turn-off-and-uninstall.md` | Removing the hook entries. Split: it is the only list of the agent-run hook wiring, so its seat-bind, report-commit, block-relay and pre-tool entries belong to bucket B. |
| `…/flow-code-agent-dispatch/scripts/agent-dispatch/agent-dispatch-validator.jq` | `dispatch.made` shape |
| `…/flow-code-agent-dispatch/scripts/agent-dispatch/dispatch-names.jq` | Shared names (listed agents) |
| `…/flow-code-agent-dispatch/scripts/agent-dispatch/generate-agent-dispatch.sh` | Writes the `dispatch.made` event from the approved plan. Split: `--reseat` reads the seat tree's HEAD (would read `worktree.cut` / facts). |
| `…/flow-code-agent-dispatch/scripts/agent-dispatch/plugin-files.sh` | Plugin files in load order |
| `…/flow-code-agent-dispatch/scripts/agent-prompt/prepare-agent-prompt.sh` | PreToolUse on Agent: replaces `DISPATCH:` with the built prompt. Split: puts the seat's WORKTREE path into the prompt (the sender reads `worktree.cut`). |
| `…/flow-code-agent-dispatch/scripts/dependencies/validate-dependencies.sh` | Install check. Split: it also checks the agent-run hooks, their rules, the mutation script, the report checkers and the `procedure-git-worktree` scripts, and prints the `settings.json` hook entries. That part goes with agent-run, and the git script checks go to each component's own `--help` checks. |
| `…/flow-code-agent-dispatch/scripts/dispatch-plan/dispatch-plan-validator.jq` | Plan shape vs installed plugins |
| `…/flow-code-agent-dispatch/scripts/dispatch-plan/generate-dispatch-plan.sh` | Writes `plan.made` |
| `…/flow-code-agent-dispatch/scripts/dispatch-plan/installed-plugins.jq` | Installed plugin map |
| `…/flow-code-agent-dispatch/scripts/dispatch-plan/list-plugins.sh` | Lists installed plugins |
| `…/flow-code-agent-dispatch/scripts/dispatch-plan/render-dispatch-plan.sh` | Plan gate render |
| `…/flow-code-agent-dispatch/views/common.jq` | Agent words and labels |
| `…/flow-code-agent-dispatch/views/denial.jq` | Deny reason layout |
| `…/flow-code-agent-dispatch/views/dispatch-plan.jq` | Plan gate layout |
| `…/flow-code-agent-dispatch/views/install-check.jq` | Install check layout |
| `…/flow-code-agent-dispatch/views/lines.jq` | Fixed lines |
| `rewrite/framework/core/engine/human-view/title.jq` | Split: its `seat_parts`, `seat_letter`, `seat_display` and `seat_title` defs are seat naming for titles. The rest is core. |
| `rewrite/framework/core/engine/human-view/SKILL.md` | Split: the table rows for the `seat_*` defs, as `title.jq` |

`…/` stands for `rewrite/domains/software-development/core/main-thread/flows/`.

## D. Flow-level

| File | Note |
|---|---|
| `rewrite/domains/software-development/core/main-thread/flows/flow-code-build/SKILL.md` | Build flow. Split: step 2.3 (dirty check), 2.4 (seat base and open), the mount and push asks, and the chains offers use git tools. They become `worktree-facts.sh`, `worktree-cut.sh`, the `git-mount` skill and the `git-push` skill. |
| `…/flow-code-build/references/drop-question.json` | Drop a chosen seat on resume |
| `…/flow-code-build/references/live-validation.md` | Live check run from the build tree. Split: trying the work in the checkout is `git-mount`. |
| `…/flow-code-build/references/merge-conflicts.md` | Taking other work into a seat. Split: the catch-up call is `worktree-catch-up.sh`, and the conflict's relay to the builder is agent-run. |
| `…/flow-code-build/references/new-work.md` | New work on a seat. Split: the move is `worktree-move.sh`. |
| `…/flow-code-build/references/resume.md` | Resume of build seats |
| `…/flow-code-build/scripts/lib/seat-title.sh` | Build seat title from its dispatch |
| `…/flow-code-build/scripts/render-live-check.sh` | Live check gate |
| `…/flow-code-build/scripts/render-what-next.sh` | What-next gate after a build card |
| `…/flow-code-build/views/drop-seat.jq` | Drop gate layout |
| `…/flow-code-build/views/lines.jq` | Fixed lines |
| `…/flow-code-build/views/live-check.jq` | Live check layout |
| `…/flow-code-build/views/what-next.jq` | What-next layout |
| `…/flow-code-test/SKILL.md` | Test flow. A tester works in its build seat's tree (one tree, two jobs). |
| `…/flow-code-test/references/resume.md` | Tester resume |
| `…/flow-code-test/scripts/lib/seat-event-gate.sh` | Shared plan file and event checks for the test gates |
| `…/flow-code-test/scripts/plan-approval.sh` | Whether the newest plan draft is approved |
| `…/flow-code-test/scripts/render-plan-gate.sh` | Plan gate |
| `…/flow-code-test/scripts/render-test-next.sh` | What-next after a test card |
| `…/flow-code-test/views/lines.jq` | Fixed lines |
| `…/flow-code-test/views/plan-gate.jq` | Plan gate layout |
| `…/flow-code-test/views/test-next.jq` | Test what-next layout |
| `…/flow-code-review/scripts/request-review.sh` (untracked) | Writes a round's `review.requested` events. **Split (pure git, no home):** it writes the diff file from `git diff base...head`, and re-pins the base with `git merge-base` after a rebase. Proposed new home: `git-worktree/worktree-diff.sh`. |
| `…/flow-code-review/scripts/review-cancel.sh` (untracked) | Cancels an open request. Split: `seats.sh handover` is agent-run. |
| `…/flow-code-review/scripts/review-cancelled-guard.jq` (untracked) | Guard |
| `…/flow-code-review/scripts/review-complete.sh` (untracked) | Writes `review.completed` once a round settles |
| `…/flow-code-review/scripts/review-completed-guard.jq` (untracked) | Guard |
| `…/flow-code-review/scripts/review-keys.sh` (untracked) | Records `review.submitted` with keys (called from the stop hook) |
| `…/flow-code-review/scripts/review-status.sh` (untracked) | A round's state from the log. Split: `--hook-event` words the next step for `block-relay-hook.sh` (agent-run). |
| `…/flow-code-review/scripts/review-submitted-guard.jq` (untracked) | Guard |
| `…/flow-code-review/scripts/review.jq` (untracked) | Shared review rules; reviewer seat naming `<lens>-review-agent-<letter>` |
| `…/flow-code-review/views/lines.jq` (untracked) | Fixed lines |
| `rewrite/framework/core/main-thread/procedures/procedure-effort/SKILL.md` | Effort lifecycle. Split: the open-work check runs `seats.sh busy`. It becomes `git-worktree/open-work.sh` and `git-mount/open-work.sh`, plus agent-run's own busy check. |
| `rewrite/framework/core/main-thread/procedures/procedure-effort/references/state-change.md` | Same split: `seats.sh busy` → `open-work.sh` lines |
| `rewrite/framework/core/main-thread/procedures/procedure-resume/SKILL.md` | Resume reads `settings.sh get` and `seats.sh list`. They become `identity-get.sh` and the tree and agent events. |
| `rewrite/framework/core/main-thread/procedures/procedure-context/SKILL.md` | Names `settings.sh` / `seats.sh` as resume reads |
| `rewrite/framework/core/main-thread/procedures/procedure-context/references/resume.md` | Same |

`…/` stands for `rewrite/domains/software-development/core/main-thread/flows/`.

## E. Not worth porting

| File | Why |
|---|---|
| `rewrite/domains/software-development/core/main-thread/procedures/procedure-seat-run/scripts/cards/cards-lib.sh` | A card printer; cards are core's gate's or main's own now |
| `rewrite/framework/core/CLAUDE.md` | Policy text only (never commit or push unasked; quote seat names). The new core states its own rules. |

## Gaps in 4.3

1. **`commit-input.sh` is marked "gone".** It is agent-run's report-to-commit-message adapter (kind from role, iteration, report text, `Effort`/`Agent-Seat`/`Iteration` trailers). Park it in agent-run, as bucket B does.
2. **Multi-tree base.** `seat-base.sh --on A --on B` cut a tree from the merge of several trees' tips, and `base_seats` (a list) fed the chain. Neither `--from worktree:NAME` (one name) nor `worktree-chain.sh` (one `from`) covers that. Its `unmerged` list (trees whose tip is not in HEAD) is also not in `worktree-facts.sh`.
3. **`unmount.sh` also loads `seats.jq`** and prints `seats`; 4.3 strips the seat pattern only from `mount-lib.sh`.
4. **Old mount records.** A version-2 record in a human's `<gitdir>/crucible/` holds `seats[{seat, worktree, seat_commit}]`. The new `lib/mount.sh` must bump the version and either read the old shape or refuse it with a clear line.
5. **`procedure-git-setup` is outside 4.3.** The identity part is ported (`git-identity`). The auto-push answer (`settings.sh` `auto_push`, the Auto-push tab in `render-git-setup.sh`) and `origin-lib.sh`'s "repo has the push remote" check have no home beyond "auto-push becomes a later setting". Proposed: `git-push`.
6. **Prune leaves git state behind.** `crucible` prune deletes `worktrees/` with the effort, but the registrations, `crucible/` branches and `refs/crucible/moved/…` stay in the repository. Nothing in 4.3 runs after a prune.
7. **No diff tool.** `request-review.sh` builds the reviewer's diff (`base...head`, merge-base re-pin after a rebase) with raw git. Design §3 gives the reviewer the builder's tree event, but no script turns a tree into a diff file. Proposed: `git-worktree/worktree-diff.sh`, read-only.
8. **No discard of uncommitted work.** The pair hold's "discard its changes" option and a gave-up run's leftovers need a tree reset to its HEAD. `worktree-move.sh` refuses a dirty tree, and no 4.3 script discards. Proposed: `worktree-move.sh --discard` with a recorded yes, or leave it to agent-run with plain git.
9. **After-end event types.** Core `events.sh` accepts `seat.pushed`, `build.committed` and `test.committed` after an effort ends. The new core must accept `push.made` (and agent-run's commit event) the same way, or a late push is refused.

## Coupling notes

Places where the pure tree scripts in 4.3 still assume agents, so the port must strip them:

- **`commit-message.jq`:** the kinds are hard-coded to `build` and `test`, each requiring the `iteration` and `agent-seat` trailers. Make the kinds and trailers free. Keep the `Effort:` trailer, because `effort-commits.sh` proves effort work by it. Keep the snapshot subject that `effort-commits.sh` recognises.
- **`commit.sh`:** "one agent's work". The 10-second unsigned fallback exists for the stop hook's time budget. Its refusal on leftover conflict markers is mirrored in the hook's block, which stays in agent-run.
- **`catch-up.sh`:**
  - It accepts only an idle builder seat.
  - It cancels on conflicts outside the builder's write scope (`write-scope.jq`, the `needs` roles).
  - It says the conflict is left "for the seat's builder", whose stop hook commits the merge.
  - Strip all three; the merge is finished by whoever runs `commit-tree.sh`.
- **`chain.sh`, `chain.jq`, `chain-sync.sh`:** they read `base_seats` from `seats.sh list` and accept only idle builder seats. Read `worktree.cut` events instead, and decide how a tree cut from several trees records its parents (Gap 2).
- **`mount.sh`, `mount-status.sh`, `mount-lib.sh`, `unmount.sh`:**
  - `mount.sh` mounts only idle builder seats.
  - The record and outputs name `seats`.
  - `mount-lib.sh` and `unmount.sh` validate seat names with `seats.jq`.
  - `mount-status.sh` reports "a seat moved since" from seat events.
  - The identity comes from `settings.sh`.
  - "Is the agent idle" becomes the caller's check (main or agent-run).
- **`push.sh`:**
  - Its `--effort`/`--seat` pair writes `seat.pushed {seat, commit}`.
  - It forces by lease "after the seat moved".
  - It is built to run inside a hook under a time limit.
  - The new `push-tree.sh` is main-run on a recorded yes. The hook-safe time limit is still needed later for auto-push.
- **`snapshot.sh` and `worktree-create.sh`:** their before/after proofs leave out "refs other working seats and their pushes move meanwhile". Keep the exclusion, reworded for concurrent trees and pushes, since several trees still run at once.
- **`effort-commits.sh`:** it takes the identity name and email from `settings.sh get`; read `identity-get.sh`. Its error text says "seats".
- **`dirty-check.sh`:** the question it prints is "where should its builders start"; the counts move to `worktree-facts.sh`, and the question goes.
- **`seat-move.sh`, `seat-open.sh`:** their rollback is driven by `seats.sh` refusing after git already acted. `worktree-cut.sh` keeps the create-then-setup rollback. The seat bookkeeping rollback goes to agent-run.
- **`uncommitted.jq`, `worktree-setup.sh`:** comments only ("the seat's worktree"; "a seat's commit stages every file git sees"). The `.gitignore` check in setup exists because `commit-tree.sh` stages everything, so keep it.
- **Identity source:** every old tree script that signs (`snapshot`, `tips-merge` via callers, `catch-up`, `chain-sync`, `mount`, `seat-base`, the hook's commit) read `procedure-git-setup/settings.sh`. All now go through `git-commit`, which reads `identity-get.sh`.
