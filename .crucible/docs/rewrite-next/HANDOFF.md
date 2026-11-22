# Rewrite of the rewrite: hand-off

Where the new Crucible framework stands, so nothing depends on chat memory. Read this, then `constitution.md` (the 17 values every choice is judged by). The earlier, layered hand-off is in `history/handoff-history.md`.

## Where things stand (2026-11-22)

- **The tree:** `new-rewrite/` in the repository. `rewrite/` is the paused older rewrite, now a quarry. `~/.claude` is the legacy framework, untouched.
- **Built:**
  - every core component up to the point of sending agents;
  - two software-development domain components;
  - the install with its check;
  - core `CLAUDE.md`.
  Each script has a repeatable evidence run, accepted by Fable.
- **Commits:** pushed to `origin/chore/framework-improvements` as `d31dcbd` (2026-11-21). Everything after it is uncommitted: the context split, the run-2 and run-3 fixes, the code rule. Nothing is deployed.
- **The context split (2026-11-22):** the context, the grill and the spec are three independent facts, each ending in its own event: `context.cut` on the human's recorded "done?", `grill.ended`, and `spec.approved`, which names the approved file sealed in `spec/`. None knows the others. Design: `reviews/context-split-design.md`.
- **Live runs** (Validator replays of the owner's run-2 prompts, judged by Fable). Reports are in `.crucible/docs/harness/runs/decisions/new-rewrite-replay/` (`report.md`, `replay2/`, `replay3/`).
  - **Run 1:**
    - the gate, the approvals and the thin prose worked;
    - no flow for the context, six spec asks.
    - That led to the context split and the decision that no flow is expected for the context.
  - **Run 2:**
    - the split worked: a "done?" gate, two spec asks;
    - the effort was offered in a plain sentence, before its skill was loaded.
    - That led to three prose fixes, among them core CLAUDE.md "load a skill before you do, offer or ask about what it covers".
  - **Run 3:**
    - the effort was offered at a gate;
    - a flow was agreed, changed, marked and reminded live for the first time.
    - That led to four fixes: a named event may be older than the flow; a step is an outcome, not a task; a spec is needed before building, too; "do" in the load-skill line.
    - The owner added the code rule (core CLAUDE.md, Always, first line): writing code or tests yourself is the exception, done only when this framework has no build or test agent for the work, or when the human explicitly tells you to.
  - **Run 4** (task brief; `replay4/`, judged by Fable):
    - every skill loaded before use, the effort at a gate, "done?" recorded, spec sealed; 5 dialogs against 18, 0 denies.
    - The brief's goal was clear, so no grill was needed: the grill is still untested. Main asked "who builds it?" after the approval. Entries were again added unread.
    - The owner's decisions (2026-11-22): unread entries are a known limit, no longer scored; a wrong line in a sealed context is fixed by a v2, nothing new; the code rule now says that with no agent, main writes without asking who should.
  - **Run 5** (`run5/`, judged by Fable): the whole chain held end to end for the first time. The chain was effort, discovery, grill (after the human's "I don't know yet"), context, spec, a five-step build flow, a 16-minute build with no questions, then marks. Main did not ask who builds.
    - Two gate-hook defects, fixed (design `reviews/gate-hook-fixes-design.md`; built on the owner's go; evidence accepted by Fable): the shape check is now a step of the hold hook, so a shape refusal keeps the card; and the missing-recommendation refusal now says a question with no real options is asked in a plain sentence.
    - Accepted, no change: a grill only after the human hedges; steps marked together at the end of one long turn, which matters once agents do the steps; 9 dialogs before the first code edit.
    - The owner chose (2026-11-22): the fixes, then dispatch. A mid-build flow change and a resume after a break are tested in dispatch's live run.
- **Next:** dispatch, talk first. The owner (2026-11-22): "Do not try to implement the dispatch. We need to talk. A lot." No design or build before that conversation.
- **Run 5's scope, kept for reference:** One run tests both: a goal reading can't settle (no stated pain, two opposite products behind it, the repo favouring neither), so a grill is needed; and the run goes on past `spec.approved` into the build, to show whether main proposes a flow there, follows the code rule and marks steps. The sandbox must not see the owner's real data (run 4 read `~/.c4-daemon`): a separate HOME for the sandbox, and a task whose answer isn't in the owner's data. Fable's additions (passed the code rule; scope sound with these):
  - Fable reviews the brief's exact opening sentence before the run: the two opposite products named, and neither the sentence nor a short read of the repo favouring one.
  - When a card or question states a reading the human hasn't chosen, the scripted human answers only "I'm not sure that's what I want", never "grill me". Scored apart: grill offered unprompted, offered after that hedge, never offered.
  - The goal is big enough that a build flow is plainly warranted, and the brief says a flow is expected. A flow agreement gate is not "asked who builds".
  - Stop at the second `flow.step.done` (a mark, the reminder, main going on); with no flow, at main's first build or test command after its first code edit.
  - The driver's watcher matches main's tool calls, not words in a card.
  - Watch: main asking "shall I start building?" in other words; the gate skill's "if you don't need it, go on" should cover it.

  After that: dispatch and spin-off, which read the three facts.

## What is built

All core components are in `new-rewrite/framework/core/main-thread/`, and both domain components are in `new-rewrite/domains/software-development/core/main-thread/`. Each script's `--help` is its contract.

| Component | Its job | Spec |
|---|---|---|
| `crucible-events` | The one writer, the one reader, and the shared helpers (lock, listing, sha256, atomic write); the guard on the writer | `specs/crucible-events.md` |
| install (`framework/core/install/`) | Prints what an install needs, and checks it is in place without changing anything | `specs/crucible-events.md` |
| `crucible-gate` | A card before every question; the question's shape; recorded answers as `gate.answered` | `specs/crucible-gate.md` |
| `crucible-effort` | An effort's life: opened, paused, resumed, closed; refuses to close over open work | `specs/crucible-effort.md` |
| `crucible-context` | The outside material the work needs: references and notes, cut on the human's "done" into sealed versions; the path and link rules | `specs/crucible-context.md` |
| `crucible-grill` | Interviewing the human, question by question, into decisions | `specs/crucible-grill.md` |
| `crucible-dynamic-flow` | A flow agreed at a gate, tracked step by step from events | `specs/crucible-dynamic-flow.md` |
| `crucible-spec` | The approved what and why, sealed in place in `spec/` at a recorded gate | `specs/crucible-spec.md` |
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
| Remove core `CLAUDE.md`'s "never send agents" line. Its rule "never write code or tests yourself when a suitable build or test agent exists, unless the human explicitly tells you to" then takes effect; today no agents are installed, so main writes code as usual. Decide then whether small work outside an effort goes to an agent, is done by main, or needs the human's "do it yourself" each time. | The dispatch build |
| The sender's inputs. It harvests the newest `context.cut`, every `grill.ended` (oldest first) and the newest `spec.approved`, and gives agents their event paths. Only the sender checks: the newest of each, still intact, the spec file still giving its sha256; one freshness check covers every pinned input. It refuses when the context's draft holds uncut content, naming it; only an empty draft with no cut shows as "none". The plan shows work in progress (an open grill, a spec draft newer than the approved one) beside any "none". Each agent kind declares the event types it takes, in one file of its own. The plan's inputs are designed once, not as three special cases. Whether the flow's agreement and the plan's approval are one gate or two. | The dispatch build |
| **Finding, owner 2026-11-22: a flow must never replicate the spec.** In run 5, main's build flow (events 8–12) restated the spec's acceptance criteria as steps and then marked them itself. That made a second, unsealed contract, approved at a gate, changeable through `flow-change.sh`. A dynamic flow is a sequence of the framework's floating pieces (skills), each ended by its own event; for the context phase: discovery, building the context, grill, spec. Two things caused it: the run-3 sentence "a step is an outcome the human would ask about", and `flow-agree.sh` accepting free-text steps. Direction: flow steps come only from the step catalogue, enforced by the script. To settle in the dispatch conversation. | Before any further live run |
| The step catalogue (`step.json` per flow-sized skill, `flow-candidates.sh`), with the shared "beside" helper built first. Until then, the flow skill's example names `context.cut`, `grill.ended` and `spec.approved`, guarded by an evidence check. | The dispatch build |
| Watch in run 5: is a grill offered when the goal is open (its trigger is only the skill's one-line description); after `spec.approved`, does main build without asking who builds, propose a flow for the build, and mark its steps. Entries added unread are a known limit and are not scored. | Run 5 |
| Count in run 5: the gates before the first code edit (the effort, the context's "done?", each grill round, the spec, any flow); outcome-changing questions asked as gates. | Run 5 |
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
| Live-run stop point for a context-phase run: a `context.cut` (or none, by the human's choice) and a `spec.approved`. Watch also: with only part of the hooks installed, the gate's "then ask" is denied, and the install check sorts it out. Does main find its effort again after a compaction? | The live run |
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
