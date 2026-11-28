# The builder and tester slices, as built: a design review, for the Fable Reviwer

By Dev Beta, at the owner's request. Talking only; the owner's go is the only go.

## Scope

**In scope:** the new, uncommitted code in `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/`. Run `git status --short --untracked-files=all .` there to list it.
- **New:**
  - `domains/software-development/core/main-thread/agent-jobs/`: the job events, the jobs view and the iteration;
  - `domains/software-development/core/agents/agent-submission/`: the shared stop hook, report checks and libs;
  - `domains/software-development/core/agents/code-builder/`;
  - `domains/software-development/core/agents/code-tester/`.
- **Changed:**
  - `framework/core/install/install-entries.sh` and `install-check.sh`;
  - `framework/core/main-thread/crucible-events/scripts/internal/event-write.sh`;
  - git-commit's `commit-tree.sh` and `commit-message.sh`.

**What to judge:**
- design and architecture;
- the module boundaries;
- separation of concerns;
- DRY and SRP;
- compliance with `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/.crucible/docs/rewrite-next/constitution.md`.

**Not in scope:**
- implementation details: jq style, the wording of a refusal line, shell idioms;
- the report schemas themselves, which you already judged.

## Background

- **The specs:**
  - `reports/build-agent.md` and `reports/build-agent-tree.md`;
  - `reports/test-agent.md` (v3).
  - Your earlier verdicts are in `reports/*-fable*.md`.
- **The proofs:**
  - `evidence/build-agent/run.sh`: 150 of 150;
  - `evidence/test-agent/run.sh`: 98 of 98;
  - both live runs pass 12 of 12 (`evidence/*/live/`).

## Choices the builder made where the spec was silent

These are worth a design eye.

1. **The shared report check is an internal script,** `agent-submission/scripts/internal/report-check.sh`, called by path. It is not a sourced shell lib. The jq rules are in `agent-submission/scripts/lib/`, and the agents include them by component-qualified name.
2. **The shared build and fix rules take parameters:** which blocker kinds are allowed, and which ones answer a failed check. The tester reuses them with its own values.
3. **The tester's `fix.submitted` reuses code-builder's event rule.** Neither component names the other, but the tester relies on code-builder being installed.
4. **`job.dispatched` grew tester-specific rules:**
   - a test job must name the newest approved plan on its tree;
   - a plan-update job must carry challenges or the human's words.
   - The approval is read from a core `gate.answered` event (`record: "test-plan"`).
5. **`jobs.jq`:** a job finishes at any event that pins its report, not only at `*.submitted`.
6. **`iteration.jq`:** the fix round is counted per agent type.
7. **`tester-facts.sh`** gathers facts from the events and git: the plan's report, the files the build under test changed, and the job's changed paths. It passes them to the rules as `.facts`.

## Questions

1. Are the module boundaries right: agent-jobs, agent-submission and one component per agent? Is anything in the wrong component?
2. Is anything duplicated, or does any script or lib do more than one thing?
3. Items 3 and 4 especially:
   - Should a shared event rule live in agent-submission?
   - Should `job.dispatched` know about tester kinds, or should each agent bring its own dispatch rule?
4. Is there anything against the constitution?

Please answer in `reports/agent-slices-design-fable.md` in this folder. Send the full result to Dev Beta, and give the owner one or two lines.
