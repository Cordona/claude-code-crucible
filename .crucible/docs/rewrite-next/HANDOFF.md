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
- **Commits:** pushed to `origin/chore/framework-improvements`: `d31dcbd` (2026-11-21), then `001c7f7` (2026-11-22: the context split, the fixes from runs 1–5, the code rule, the gate-hook fixes). The live-run reports in `.crucible/docs/harness/runs/decisions/new-rewrite-replay/` stay uncommitted (raw transcripts). Nothing is deployed.
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
- **Next, before dispatch (owner, 2026-11-22):** make dynamic flows work as Fable proposed. Each floating skill declares its step in a `step.json`; `flow-candidates.sh` lists them; `flow-agree.sh` refuses any other step. Main proposes a flow once there is enough evidence, before any work starts, for example: context, grill, spec. Git identity and worktree cuts later become floating steps too. Proving this on the context phase comes first. Then dispatch, talk first.
  - The owner's decisions (2026-11-22, on Fable's view):
    1. Discovery has no step of its own: the step is "build the context", ended by `context.cut`, and discovery is how it is done.
    2. The flow skill tells main to run `flow-candidates.sh`, and its description claims "when an effort's work is about to start". The effort skill doesn't mention it and no hook runs it; a hook line is added only if a live run shows main skipping it.
    3. "Beside" is settled now. A component's neighbours are the folder it sits in, as it was called; installed, that is the skills folder. One shared helper serves the open-work scan, the event-rule lookup and the catalogue scan, and the install links every component, `crucible-events` included.
    4. Every step ends in an event, never a criterion; the human's judgement is a recorded gate. `step.json` fields: `do`, `uses`, `done_when`, `fits`. There is no `flows` field, no order and no `optional`.
  - The stage field (the owner and Fable agree, 2026-11-22). Each `step.json` entry declares `stage`, a list of at least one name, and `flow-candidates.sh --stage <name>` filters on it; the scan can also list the stage names it finds. Only the scan reads it: no script checks the order of stages, and core's prose gives no sequence. Core owns only `prepare`; a domain declares its own stages, for software development build, test and review. There is no pre-dispatch stage: a setup step such as identity or a worktree lists every stage it serves. The flow skill tells main: before work starts, scan `prepare`; once the pre-work is done, list the stages and scan the one the next work belongs to.
  - Enforcement (the owner, 2026-11-22: "We do not know enough. For now, I would say a flow is mandatory but can be changed"). Fable's view, kept for the design: enforce only at dispatch, with no way round it; the sender matches an open step by the event the send will produce; no recorded "no flow" answer. Two gaps if a flow is mandatory: `flow-change.sh` needs only a reason today, not the human's recorded yes; and its `add` and `revise` ops accept free-text steps and criteria, so the catalogue guard must apply there too. Still open: what exactly is refused while no flow is agreed. Open for dispatch: one step against several sends (parallel agents, fix rounds).
  - Decided (the owner, 2026-11-22, on Fable's view; this replaces "mandatory" above):
    - At prepare, the flow is offered and the human can say no. Nothing refuses: prepare work has no start a script can guard, and its three facts stay independent. If a live run shows main not offering it, add one reminder line to the flow's existing Stop hook.
    - The flow is enforced only at dispatch, with no way round it.
    - Flow changes need the human's recorded yes once dispatch enforces the flow. That is part of the dispatch build.
    - With the catalogue: `flow-change.sh add` takes only catalogue steps, and `revise` probably goes.
  - **Direction for code work after prepare (owner, 2026-11-22):**
    - **Phases:**
      - prepare (core): context, grill, spec;
      - set up (software domain): git identity, and a worktree per job where one is needed, with main reasoning about which repos and what to cut each tree from;
      - dispatch: send each job's agent with its plugins and its input events, each optional and shown as "none" when missing.
    - **The agent's run is sealed:** the stop hook commits and writes the result event, which ends the flow step.
    - **"Job" replaces "part":** one task for one agent, in one repository and one language.
    - **Orphan worktrees are allowed but stay visible:** the worktree piece's `open-work.sh` lists them, and dropping one is its own event.
    - **Three gates:**
      - git identity, its card printed by a script from the resolved identity;
      - worktrees, a free-form card showing main's reasoning, with questions and a recommendation;
      - dispatch, a script-printed card with one block per job: agent and tech, standards, input event paths or "none". One card per dispatch round; the old grouping rules are dropped.
    - **The flow proposal card** stays printed by a script from main's flow JSON (`flow-card.sh`).
    - **After the dispatch yes, the old mechanics carry over:** `dispatch.made` per job, the one-line `DISPATCH:` prompt, the prompt hook building the message, the bind hook, and the stop hook committing.
    - **Open:** a job with no worktree. The lean is no commit in the human's checkout; the result is a report only.
    - **Fable's view (2026-11-22) and the owner's answers:**
      - **Decided:**
        - every agent that writes gets a worktree, and only read-only agents (a reviewer, a reader) run without one; a small in-place fix is main's own work under the code rule;
        - (A) one step is one job, and a fix round is a new step added on the human's recorded yes;
        - (B) an agent that ends badly (blocked, nothing to commit, cut off) writes an event;
        - (D) each agent kind declares the event types it takes and the one it writes;
        - (C) the prompt hook refuses any agent call with no valid `DISPATCH:` line behind it, while Claude Code's built-in read-only helpers, such as search, stay allowed.
      - **To discuss one by one:**
        - dispatch is not a stage, so the domain's stages are set up, build, test and review;
        - port the old dispatch by its behaviour as small single-job scripts, not by copying the 1,300–1,500-line scripts;
        - the identity gate comes once per effort and repository, and the worktree gate only when there is a real choice, otherwise as a line on the dispatch card.
      - **Fable's caution:** build and prove the pieces in the order a single job needs them, one builder in one repository first.
  - Design: `reviews/step-catalogue-design.md`. Fable passed it with fixes A–D. The owner's go came on 2026-11-22.
  - **Built (uncommitted), with the owner's renames on Fable's view:**
    - each step is declared in `flow-step.json`, in the order name, stage, does, propose_when, ends_with, skills;
    - `skills` is a checked list;
    - `ends_with` replaces `done_when`, in flow events too.

    The specs (`specs/crucible-dynamic-flow.md`, `specs/crucible-events.md`) describe what is built; the design keeps the old field names. Every evidence run is rerun; Fable reproduced them and accepted the catalogue, and its one prose fix is in ("Once those steps are done"). The preflight passed: linking a component folder with no `SKILL.md` gives no warning, and the skill list is unchanged.
  - **Live run 6** (`run6/`, prepare stage only, judged by Fable):
    - main proposed a flow of declared steps before any work (context, then spec, with the grill left out because the goal was clear), on the card `flow-card.sh` prints;
    - when the human hesitated, main added the grill through a flow change;
    - every step was marked by its own event within seconds, and the flow was ended;
    - main loaded each step's skills before working on it;
    - after the flow, main saw only `prepare` among the stages and went on without a flow;
    - 11 dialogs before `spec.approved`, none denied.
    - One slip: the flow gate was first asked unrecorded, and `flow-agree.sh` refused. Fixed in the flow skill with the spec skill's proven sentence (read `flow-agree.sh --help`, ask at that recorded gate); Fable passed the fix.
    - To watch: main offered "no flow" as "no pre-work".
    - The owner decided (2026-11-22): a flow is offered on every effort, small ones included; it is worth the click. Until dispatch brings build steps, a build main writes itself has no flow. The owner (2026-11-22): "Do not try to implement the dispatch. We need to talk. A lot." No design or build before that conversation.
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
| ~~What "beside" means~~: settled and built with the step catalogue (`crucible-events/scripts/lib/beside.sh`; the install links every component and runs hooks through the links). | done |
| Remove core `CLAUDE.md`'s "never send agents" line. Its rule "never write code or tests yourself when a suitable build or test agent exists, unless the human explicitly tells you to" then takes effect; today no agents are installed, so main writes code as usual. Decide then whether small work outside an effort goes to an agent, is done by main, or needs the human's "do it yourself" each time. | The dispatch build |
| The sender's inputs. It harvests the newest `context.cut`, every `grill.ended` (oldest first) and the newest `spec.approved`, and gives agents their event paths. Only the sender checks: the newest of each, still intact, the spec file still giving its sha256; one freshness check covers every pinned input. It refuses when the context's draft holds uncut content, naming it; only an empty draft with no cut shows as "none". The plan shows work in progress (an open grill, a spec draft newer than the approved one) beside any "none". Each agent kind declares the event types it takes, in one file of its own. The plan's inputs are designed once, not as three special cases. Whether the flow's agreement and the plan's approval are one gate or two. | The dispatch build |
| **Finding, owner 2026-11-22: a flow must never replicate the spec.** In run 5, main's build flow (events 8–12) restated the spec's acceptance criteria as steps and then marked them itself. That made a second, unsealed contract, approved at a gate, changeable through `flow-change.sh`. A dynamic flow is a sequence of the framework's floating pieces (skills), each ended by its own event; for the context phase: discovery, building the context, grill, spec. Two things caused it: the run-3 sentence "a step is an outcome the human would ask about", and `flow-agree.sh` accepting free-text steps. Direction: flow steps come only from the step catalogue, enforced by the script. To settle in the dispatch conversation. | Before any further live run |
| ~~The step catalogue~~: built 2026-11-22 (`flow-step.json` per component, `flow-candidates.sh`); see "Where things stand". | done |
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
