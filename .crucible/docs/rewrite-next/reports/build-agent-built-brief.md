# The build agent's submission, built: brief for the Fable Reviwer

By Dev Beta. The scripts for `build-agent.md` are built in new-rewrite, as the agreed tree (`build-agent-tree.md`) with the owner's change: the steps sit directly in `hooks/subagent-stop/`. Please judge the evidence and the six decisions below. Talking only; the owner's go is the only go.

**The evidence** is in `evidence/build-agent/`:
- `run.sh`, the proof;
- `run.out`, the full output: 116 pass, 0 fail, run twice from a clean start by me after the fix below;
- one folder per case of `build-agent.md` §8, each with `report.json`, `hook-output.txt`, `event.json` and `commit.txt`;
- `repair-lines.txt`, every §4 repair line checked word for word (33 rows).

**The code:**
- `new-rewrite/domains/software-development/core/main-thread/agent-jobs/`;
- `new-rewrite/domains/software-development/core/agents/agent-submission/`;
- `new-rewrite/domains/software-development/core/agents/code-builder/`;
- changed: `new-rewrite/framework/core/install/install-entries.sh` and `new-rewrite/domains/software-development/core/main-thread/git-commit/scripts/main/commit-tree.sh` (a new `--unsigned` option).

**Fixed by me after the build:** the allowed gates were the agent's own list. They are now the spec's (`report-schemas.md` §1): `format`, `lint`, `typecheck`, `test`, `build`, `scan`, `manual`.

## Decided by the builder where the spec was silent

1. **A `fail` gate needs its `failing` list, not a note.** `not_run` and `narrowed` need a note. The spec's table said a note is needed on anything that isn't `pass`, but its own examples had `fail` gates without one.
2. **Two writers for `build.submitted` and `fix.submitted`:** `submission-event.sh`, and `recover-submission.sh` (recovery from the `Job` trailer, case 8). Each rule allows both.
3. **The pin's hash sources the core's `crucible-events/scripts/lib/sha256.sh` from the domain.** That goes against git-identity's comment that the domain never sources the core.
4. **`git-commit` gained `--unsigned`** in `commit-tree.sh`, the smallest change; before, it fell back to unsigned only when signing failed. `commit-message.sh --help` still says "no effort key", which is now stale.
5. **A new fix loop is recognised only by `sent_back` on the dispatch.** A second fix choice can't be told apart until the fix choice is an event.
6. **Event rules that include a lib use `{search: "./../scripts/lib"}`.** That is proven on jq 1.8.1 only; jq 1.6 isn't installed.

**Also built:**
- three shared libs: `agent-jobs/scripts/lib/jobs.jq`, `code-builder/scripts/lib/submitted.jq`, `agent-submission/scripts/lib/stamps.jq`;
- a minimal `job.assigned` rule (job, agent, name), written by the proof's fixture, so that the hook can find a job by the agent id;
- the hook fails open on a fault: the stop goes through, with a message to the human, never a loop;
- the event's `commit` is the full sha;
- `by` is the step script's name;
- an accepted report is rewritten with its empty lists pruned, before it is pinned.

## Questions

1. Does the evidence show what the spec promises?
2. Decisions 1 to 6: accept, change, or settle elsewhere?
3. Anything in the built tree that drifts from the agreed tree or from new-rewrite's conventions? Judge the design and the evidence, not the implementation's lines.

Please answer in `build-agent-built-fable.md` in this folder, send the full result to Dev Beta, and give the owner one or two lines.
