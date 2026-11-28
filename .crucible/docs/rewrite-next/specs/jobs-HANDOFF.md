# Jobs: handoff (2026-11-27, before compaction)

Everything is uncommitted in `new-rewrite/` (about 138 files). Never commit or push unasked.

## What exists and is proven

- `domains/software-development/core/main-thread/jobs/` (a group; installs as `jobs-*`):
  - `define/`: `job.defined` (one rule for every kind), `job-resolve.sh`, `job-card.sh`, `job-define.sh`, `kinds/{build,test,review,test-plan,test-plan-challenge,test-plan-update}.json`.
  - `assign/`: the door `job-assign.sh`, `job.assigned` (both shapes), four hooks (start-from-door, job-tree, job-assigned, job-sent).
  - `track/`: moved from the deleted `agent-jobs/`: the job view (`jobs.jq`, kind-blind, passes `refs` by name), `job-of.sh`, `agent-job.sh`, ended/stalled/refused, the gone-jobs Stop hook, `end-job.sh`. The frozen `job.dispatched` stays only for the four kinds not moved (build-fix, test-fix, foreign-review, external-review) and gives its inline plan as a plan ref.
- `core/agents/agent-init/`: `agent.initialized` rule, `agent-files.sh` (user-level agent files `<base>-<set>.md`), `agent-name.jq`, `agent-type.sh` (base from a generated type).
- Plugins: 17 became 50 skills (base + `-build`/`-review`), model-invocable, short descriptions; a part is optional. Installer links them; also groups, `kinds/`, SubagentStart + WorktreeCreate events.
- Core changes: `CLAUDE.md` Never line "Start an agent to do the effort's work except through a skill that starts agents" (narrow reach; the owner may widen); `show-card.sh` keeps a recorded card's gate when the same card is shown again without `--record`; git-worktree prose: cut only once a gate showed repository and base.
- Live (real agents, sandbox config): build, test, review cold+hot, and the trio plan → challenge → rework; one gate per job; every agent's skills byte-equal. `evidence/jobs-live/results.md`.

## Specs, reviews, evidence

- Specs: `specs/jobs-1-defined.md`, `specs/jobs-2-4-dispatch.md`, `specs/jobs-structure.md`. Shapes: `spikes/dispatch/job-shapes-final.md`.
- Fable: `reports/jobs-*-fable.md`, `reports/plugin-skills-main-fable.md`.
- Runs (all green at handoff): `evidence/{agent-jobs,build-agent,test-agent,review-agent,jobs-1,jobs-2}/run.sh` = 69, 403, 121, 114, 33, 65. Live: `evidence/jobs-live/live.sh setup|plan|start|collect|unlink` (sandbox `/Users/Shared/crucible-sandbox/jobs-live`, config `/Users/Shared/crucible-sandbox/event-jobs/cfg`, tmux `jobs-live`; unlink after).

## Owner decisions (settled)

One `job.defined`; kinds as JSON in `jobs/define/kinds/`; everything job-related under `jobs/`; `agent.initialized` is the agent's (agent-init) but written by assign's one start hook; user-level agent files; `known_failures` as `work.known_failures`; `approval_gate {ref, position}`; `input_refs` seqs only; `work {tree, range, loop {iteration, round?}}`; facts are events (words = a `gate.answered` ref); legacy framework removed at the real install, so no skill-name clash; no hook blocking main from plugin skills (count main's Skill calls on plugin names in every live run; 0 so far). Stop asking for a go once a plan is approved; report at the end.

## Open

- **Remote reviews (in progress), design `specs/jobs-remote-reviews.md`, approved by Fable (`reports/jobs-remote-*-fable.md`, `remotes-workers-fable.md`).**
  - **Built and proven:**
    - `core/main-thread/remotes/`: the read scripts `internal/{change-read,review-read,change-commits}.sh`, the libs `{remote.sh,github.jq,gitlab.jq,pin.sh}`, the main scripts `main/{change-fetch,review-fetch}.sh`, the rules `events/remote-{change,review}.fetched.jq` and `SKILL.md` (Fable must read it before a session uses it).
    - dev-base `safe-link.sh`, used by trackers too.
  - **The evidence:**
    - GitHub on stubs of the owner's scrubbed samples: `evidence/remotes/run.sh`, 35 of 35.
    - GitLab live and read-only, on people-spheres MRs (see the memory `remotes-gitlab-test-targets`), and the events in a scratch config.
    - Findings: `spikes/remotes/{gitlab,github}-findings.md`, `worker-answers.md`.
    - State is mapped to open, merged or closed, by the owner's decision.
  - **Not proven:** GitHub's real query and paging, the link from a line thread to its review (the samples collapse ids), GitHub's base (merge-base(base.sha, head)).
  - **Built since:**
    - the kinds `foreign-review` (`range: change`; resolve cuts the tree) and `external-review` (`range: change` on a used tree; refs `review`, `change` via the review, `earlier` same change), with the kind-file words documented at the top of `job-resolve.jq`;
    - the reviewer's `review-threads.jq` (new, changed or seen against `refs.earlier`) and the prose lines;
    - a start Claude Code refused no longer blocks its retry (`start-from-door.sh`);
    - evidence green: jobs-1 44, jobs-2 66, review-agent 116, build-agent 403, test-agent 121, agent-jobs 69, remotes 49, trackers.
  - **Live:** `evidence/jobs-live/results.md`, the fourth run (`remotes-live.sh`, a synthetic GitLab MR through a `glab` stand-in). Foreign review accepted; external review accepted. The second-pass gap is fixed with `earlier` (no drift).
  - **Open:**
    - the repair loop at the handback (task #86), done: `spikes/handback/probe-results.md`, `specs/jobs-repair-plan.md`, the hook `agent-submission/hooks/pre-tool-use/hand-in-at-handback.sh`; build-agent 414. Live run 5 had no refusal, so a real agent's refused → repaired → accepted is still shown only in two halves, and a twice-refused job is still unseen;
    - task #85, closed by the handback check; `source` is drop-and-stamp;
    - task #84: the remote watch skill, design talk first;
    - where `agent-init` moves (owner's call: `main-thread/jobs/agents` or `main-thread/agent-init`).
- Then the fix loop: build-fix, test-fix, re-review (`fix.chosen`, rounds, earlier findings); then delete `job.dispatched` and `iteration.jq`.
- Later (owner idea): a main skill to watch a remote. After a PR/MR opens, main offers to poll it for reviews on a schedule (default every 10 min); after we push fixes, to poll for the re-review; after our foreign review, to poll whether it was addressed. Talk the design first. Builds on `remotes/` (`remote-review.fetched`). A floating piece, its own skill, a candidate step for an adaptive flow (a `flow-step.json` like git-push's).
- agent-init has no SKILL.md by design: main reaches agent-files.sh only through the command job-card.sh prints (owner asked 2026-11-27; proposed to keep it so).
- **Next after the push (owner, 2026-11-28), in this order:**
  1. **The coupling audit, one big one, verified by Fable.** Find the coupling that crept back in against the owner's rule: loosely coupled and highly cohesive, so a change in one thing doesn't cascade. Seen: moving agent-init touched 7 scripts in 3 components, which source its libs by installed path; moving the plugins touched none. Map every component-to-component edge (sourced libs, called scripts, events, hard-wired paths), judge each as a contract or a reach-in, fix the reach-ins, and prove it with the evidence runs.
  2. **The shared agent pieces:** agent-conduct, agent-report and agent-submission, perhaps under `agents/shared/`, one folder per piece, not split into skills and hooks. The installed names change with the group prefix.
  3. **Main's pieces in `main-thread` only?** `agents/` would know only what concerns subagents (owner unsure). Candidates: `agent-submission/scripts/main/recover-submission.sh`; who owns agent-init's libs, which the agent-side hooks source.
  4. **Missing skills:** jobs/agent-init and jobs/track (main runs their scripts); dev-base is plumbing.
  5. **Adaptive flow step candidates in software development:** `build`, `test` and `review` in a `work` stage (jobs-define and jobs-assign); `review-change` and `judge-review` (remotes). Not steps: agent-init, track, dev-base, code-context, trackers.
- Later (owner, 2026-11-28): the installation logic as a whole was never designed together; refine how the framework installs at some point. Today: components link flat into skills/, a group's folders get its name as a prefix (jobs/define → jobs-define).
- Later: `cut-worktree` step's place in the catalogue (owner: think later); work steps build/test/review in the flow catalogue; the Never line's reach.
- The owner's old `rewrite/` changes (pre-existing, not ours): keep or discard, unanswered.

## Working rules

Kind-file words are listed, one line each, at the top of `jobs/define/scripts/lib/job-resolve.jq`. `via` and `same` both came in for external-review on 2026-11-27: a third word that fills a ref is a signal to stop and look (Fable).

Fable ("Crucible Fable Reviwer") reviews every design and prose piece before it runs; her approval is not the owner's go. Approve JSON shapes with the owner first. Script over prose. Validate live in auto mode in the sandbox, never the owner's `~/.claude`. Kill by tmux name or PID only. Give paths, not file contents. Concise.
