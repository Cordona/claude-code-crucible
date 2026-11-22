# Rewrite of the rewrite: hand-off

Where the new Crucible framework stands, so nothing depends on chat memory. Read this, then `constitution.md` (the 17 values every choice is judged by). The earlier, layered hand-off is in `history/handoff-history.md`.

## Where things stand

- **The tree:** `new-rewrite/` in the repository. `rewrite/` is the paused older rewrite and now a quarry. `~/.claude` is the legacy framework, untouched.
- **Built:** every core component up to the point of sending agents, plus two software-development domain components, an install file and its check, and the core `CLAUDE.md`. Each script has a repeatable evidence run, and Fable has accepted the results. Nothing is committed or deployed.
- **Not yet proven:** how main behaves with these skills and hooks in a real session. That is the live run, R1 up to the point of dispatch. Crucible Validator has the scope and starts on the owner's go.
- **Next:** the live run; then dispatch and spin-off, which run the context's cut.

## What is built

All core components are in `new-rewrite/framework/core/main-thread/`, and both domain components are in `new-rewrite/domains/software-development/core/main-thread/`. Each script's `--help` is its contract.

| Component | Its job | Spec |
|---|---|---|
| `crucible-events` | The one writer, the one reader, and the shared helpers (lock, listing, sha256, atomic write); the guard on the writer | `specs/crucible-events.md` |
| install (`framework/core/install/`) | Prints what an install needs, and checks it is in place without changing anything | `specs/crucible-events.md` |
| `crucible-gate` | A card before every question; the question's shape; recorded answers as `gate.answered` | `specs/crucible-gate.md` |
| `crucible-effort` | An effort's life: opened, paused, resumed, closed; refuses to close over open work | `specs/crucible-effort.md` |
| `crucible-context` | What agents work from: draft, cut, sealed versions, the path and link rules | `specs/crucible-context.md` |
| `crucible-grill` | Interviewing the human, question by question, into decisions | `specs/crucible-grill.md` |
| `crucible-dynamic-flow` | A flow agreed at a gate, tracked step by step from events | `specs/crucible-dynamic-flow.md` |
| `crucible-spec` | The approved what and why, recorded at a gate | `specs/crucible-spec.md` |
| `crucible-discovery` | A how only: read first, ask second | none: the SKILL.md is the whole of it |
| domain `trackers`, `code-context` | A GitHub or GitLab issue, or a commit, copied into the context | `specs/software-development-domain.md` |
| core `CLAUDE.md` | The rules that hold everywhere: how main talks, Never and Always | the file itself |

**Evidence**, each a run script with its full output, run from `/`, in `evidence/`: `events`, `effort`, `context`, `grill`, `spec`, `gate-answers`, `dynamic-flow`, `fixes`, `tracker` (through the installed layout; it reads GitHub), and `installed` (every component through its skill link). `lib-decide.sh` answers one recorded gate through the real hooks. Every run takes each folder and path from a script's stdout and hides no output.

**Reviews by Fable**, in `reviews/`: `core-completeness-review.md` and `compliance-audit.md`, with `compliance-fixes.md`. Every finding is built or recorded below.

## Recorded, not built

Each item waits for its trigger.

| Item | Trigger |
|---|---|
| What "beside" means. Two scans differ once installed: effort-close looks for `open-work.sh` among the skills folder's entries, so it sees domain components, while event-write looks for a type's rule among core's real folders, so it doesn't. Decide it once, for both. The recommendation: beside means the installed skills folder, and the install links every component, `crucible-events` included. | The first domain component that writes an event (seats, with dispatch) |
| Remove core `CLAUDE.md`'s "never send agents" line | The dispatch build |
| The agent's side: how an agent reads its context; the agent half of handing over an artifact; reading a grill (the answers list also holds "Dropped:" and "Deferred:" notes, so read the status first, and take the last entry as the answer only when settled); a running agent gets a revised spec's path | The dispatch build |
| Decisions before or outside an effort leave no proof | When `effort-start`, or a commit outside an effort, needs a recorded gate |
| A commit piece that refuses without a recorded yes ("never commit" is prose until then) | The VCS work |
| Shared card rules | A second script-printed card |
| Metrics: one read-only script that counts on demand, the one sanctioned reader of transcripts | When old and new are to be compared |
| Pruning old efforts (the flow hook looks at every effort at each stop) | When efforts pile up |
| Answers given from a dashboard | A real case |
| Jira, as its own piece, never through the legacy skills | The first real Jira task |
| The domain skills' names (`trackers`, `code-context`); core's carry `crucible-` | The owner's call, before any deploy |
| code-context refuses a repository's first commit (no parent, so no diff), and its refusal names the wrong reason. A note, not a fix. | When someone next touches that script |
| Logged-in GitLab comments, not yet proven | The live run, on a host the owner uses |
| Watch in the live run: with only part of the hooks installed, the gate's "then ask" is denied, and the install check sorts it out. Does main find its effort again after a compaction? | The live run |
| The old skills `standard-artifact-handoff` and `procedure-resume` live on as one line each in core `CLAUDE.md`. `procedure-context-efficiency` is left out (owner's call). `procedure-metrics` is the metrics row above. Don't port them by reflex. | none |
| Fable's four success tests and the acceptance run | Open for the owner |

## How we work

- **Scripts:**
  - design, then Fable reviews the design and its compliance;
  - the owner's explicit go;
  - build, and run every case with full output from a neutral folder;
  - Fable judges the results, never the implementation.
- **Prose:** written under the owner's standing go, then Fable verifies it against the constitution and checklist 13, then the review is applied.
- **The owner's go is the only go.** A relay from Fable is confirmed in this session first. Never commit, push or deploy into `~/.claude` unasked.
- **Fable** is the "Crucible Fable Reviwer" session, reached by SendMessage. Every Fable result is shown to the owner.
- **Writing rules:**
  - no versions;
  - prose names a folder, not its scripts, except one the prose tells main to run at a given moment;
  - a question example is the AskUserQuestion JSON;
  - every event field has a named reader;
  - one rule file per event type, found by the writer;
  - small single-job scripts, no hub;
  - core is domain-agnostic, and a domain reaches core only through its public scripts, as a neighbour skill;
  - no Never/Always lists in hows, and no exit-code tables or fixed question files;
  - no prose that leans on other prose;
  - one current spec per component; earlier designs go to `history/`.
- **Words:** a piece is a script with one job; a how is a short standalone prose skill; a gate is a decision point with the human; an effort is a folder and its event log; a flow is agreed steps toward one goal, kept as events. Every framework skill is named `crucible-<what it is>`.
- **The success criterion (owner):** "if we can achieve the same result without micromanaging the model and if we have small self-contained, loosely coupled, highly cohesive pieces of code and prose that the model can use to assemble dynamic flows that cover every possible scenario negotiated by the human and main that can also be tracked for completeness."
- **Do not modify** `flow-json-projection.md`; the owner is working through it.
