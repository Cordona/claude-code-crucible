# Rewrite of the rewrite: hand-off (2026-11-20)

Everything decided or proposed about the next Crucible framework, so nothing depends on chat memory. Read this, then `constitution.md`.

## Files in this folder

| File | What | Who edits |
|---|---|---|
| `constitution.md` | The 17 core values. The judge of every later choice. | Owner sharpens it; Claude edits only on ask |
| `flow-json-projection.md` | A sketch of flows as JSON, using the effort as the example | **The owner is working through it. Claude must not modify it.** |
| `HANDOFF.md` | This file | Claude |

## Why a rewrite of the rewrite

- The current rewrite (`rewrite/`) has about 190 scripts (~41k lines) and about 87k words of prose in 112 files; main-thread flows and procedures alone are ~41k words.
- **The scripts are mostly sound pieces.** The prose is the problem:
  - flows written as decision trees that try to predict every scenario;
  - every live-run slip patched with more prose (exit-code tables, fixed question files, Never/Always lists);
  - invariants written as instructions instead of script refusals;
  - prose files that depend on each other, so one change cascades.
- **The owner's realisation:** "We are surrounding the model with tons of rules and decision trees and scenarios, and we can't predict every possible scenario." The workflows are the owner's flows of today, not every user's, and not tomorrow's. Opus 5.x needs much less scaffolding.
- **The plan:** a new framework in a new folder. The current rewrite becomes a quarry: proven pieces are copied from it, not rewritten. The legacy framework (`~/.claude`) stays untouched; never deploy into `~/.claude` without the owner's go.

## Vocabulary (settled)

| Word | Meaning |
|---|---|
| **Piece** | A deterministic script (or small skill wrapping scripts) with one job. Its `--help` is its whole contract. It refuses to protect invariants; it never steers. |
| **How** | A small, standalone prose skill on how to do one kind of work (grill, discovery, review). It never says what comes before or after it. Not over-instructive (Opus 5 checklist). |
| **Gate** | A decision point with the human: main computes the question from the situation, a script renders it, the human answers. |
| **Effort** | The container for one piece of work: a folder and its event log. |
| **Flow** | An agreed series of steps toward one goal, as JSON in an event. |

- "Procedure" is dropped. "Flow" no longer names a kind of skill.
- **Fixed flows dissolved.** Checked against `procedure-effort`: the only truly fixed sequence is starting an effort (offer, answer, name, start: SKILL.md steps 1–4), and it runs before the effort's folder and log exist (chicken and egg). It is just one gate plus one piece. Everything else there is lifecycle (states and moves, a piece) or presentation. A fixed sequence is either mechanical (inside one script) or a rule (a script's refusal).
- So the new framework has two shapes: **pieces** (with lifecycles, refusals and views) and **dynamic flows** (agreed per goal, recorded as events).

## Naming (settled)

- Every framework skill gets one shared prefix, `crucible-`, to avoid clashes with legacy and other skills in `~/.claude/skills`. The rest of the name says what it is, never a kind word: `crucible-gate`, `crucible-effort`, `crucible-context`, `crucible-flow`, `crucible-events` (today's `crucible`), `crucible-cards` (today's `human-view`). Hows are named the same way: `crucible-grill`, `crucible-discovery`, `crucible-review`.
- It's `crucible-gate`, not `approval-gate`: not every gate approves; some choose.
- The owner proposed `approval-gate` and `framework-effort`/`crucible-effort`; Claude proposed the `crucible-` prefix and plain `gate`. The owner answered "Good".

## What success means (owner, 2026-11-21, given to Fable)

> The new rewrite is a success "if we can achieve the same result without micromanaging the model and if we have small self-contained, loosely coupled, highly cohesive pieces of code and prose that the model can use to assemble dynamic flows that cover every possible scenario negotiated by the human and main that can also be tracked for completeness."

Fable's reading of it, as four tests (proposed, not yet accepted by the owner):
1. **The same result:** a real task reaches context, build, test and review with the old guarantees.
2. **No micromanaging:** the prose stays thin after live runs. A live slip is fixed in a script, or accepted, never patched with prose.
3. **Small, self-contained pieces:** a change to one piece touches one piece.
4. **Dynamic flows, negotiated and tracked for completeness:** agreed, changed on the go, with what's done and what's left visible at any time.

It follows that flow tracking is part of success, not a later extra (this overrides the earlier "tracking deferred" line). The proposed acceptance run is three live efforts: a routine one, one changed mid-flow, and one nobody designed for. Each must reach its result, the events alone must show what's done and what's left, and nothing may be added to the prose afterwards.

## The entry point

1. Plain conversation: no framework.
2. Main judges the work is effort-shaped (several steps, worth tracking, likely to span sessions, agents or code changes), without offering too early.
3. **`crucible-gate`:** offer an effort (or resume one that fits), with a recommendation.
4. **`crucible-effort`:** on yes, `effort.sh start` makes the folder and writes `effort.started`.
5. The first dynamic flow: main and the human agree how to build the context (discovery, grill, discussion, spec, spec gate), then follow it.

So the build order is `crucible-gate`, then `crucible-effort`, then `crucible-context` and `crucible-flow`.

## Dynamic flows (agreed)

- Main proposes the steps from the hows it knows and from flows that worked before. The human accepts, changes or replaces them at a gate. The agreed steps are JSON in a `flow.agreed` event; main follows the JSON, not prose.
- **Changes on the go** (for example, the human adds a grill): a new `flow.changed` event pointing at the flow by seq, with operations add, skip (with a reason) or reorder. `flow.agreed` is never edited. Step ids are stable and never reused. When the human asks for the change, their words are the agreement (no extra gate). When main wants a change, it asks at a gate.
- **The flow's id** is the seq of its `flow.agreed` event; no separate id.
- **Smallest version first:** only `flow.agreed` and `flow.changed`. Progress tracking is deferred until a real run shows main losing track. If it's ever needed: each step's `done_when` names an event the framework already writes, and a reader script derives "done" by matching events after the flow's seq, so pieces never need to know a flow id and main never writes "done".
- **Complex work** (build, test, review): two layers. The agreed flow orders the big steps (negotiable: which lenses, a challenge or not, the cap). The pieces with their invariants run each step deterministically (seats, keys, completion, harvest, caps). Scripts refuse invalid orders, so no agreement can produce an unsafe run. A fix loop is one step with parameters, not rounds spelled out. Watch for negotiation fatigue: routine work must be a one-click accept of the recommended flow.
- **Lessons from the true-flows experiment** (Dev Gamma, late October, `.crucible/docs/harness/runs/decisions/true-flows/`, `r3-results.md`, `r3h-results.md`):
  - injecting steps one at a time cost +14–21% tokens, with no reliability gain on light and medium tasks;
  - main dropped the driver in 3 of 8 two-developer runs once background replies arrived;
  - a Stop hook fixed that (5 of 5, about +5% cost);
  - the new idea differs: the whole agreed JSON at once, with main following it with judgment.

## The fundamental skills

| Skill | Job | Status |
|---|---|---|
| `crucible-gate` | Every decision point | Exists as `procedure-approval-gate`; unify (below) |
| `crucible-flow` | Agree, change, show a flow (`flow.sh`) | **New** |
| `crucible-events` | The fact log (`events.sh`) | Exists (`crucible`) |
| `crucible-effort` | The container | Exists (`procedure-effort`); simplify drastically (below) |
| `crucible-cards` | Compact deterministic cards and lines (`show.sh`) | Exists (`human-view`) |

Each how can be its own small skill: Claude Code shows every skill's one-line description natively, so main finds hows without a catalogue file.

## The unified gate

**As built (2026-11-21), superseding the older lines below:** there is no `gate.sh` or `gate.jq`. `crucible-gate` is `SKILL.md`, `scripts/show-card.sh` (any card file, printed and recorded as owed) and three hooks: `hooks/stop/require-card-shown.sh`, `hooks/pre-tool-use/hold-question-until-card-shown.sh` and `hooks/pre-tool-use/check-question-shape.sh`. Main writes the AskUserQuestion itself. Every question needs a shown card; Fable recommends narrowing that (open for the owner). Spec: `specs/crucible-gate.md`.


**Settled 2026-11-20: cards stay, questions go dynamic.**
- **Rich cards keep today's approach:** the dispatch plan, build report, test report and review report cards stay script-rendered from their templates. They give determinism and token efficiency where the content is structured and frequent.
- **The questions become generic:** no fixed question files. Main computes the options from the concrete scenario. One `gate.sh` and one validator build the AskUserQuestion payload. A gate's facts may point at a rich card shown above it.
- **The `crucible-gate` skill says:** the questions are dynamic and built from the situation; there is always a recommended option, first, with why; every option carries its facts; the human can always answer in their own words.
- Presets for frequent gates: rejected for now; add one only if a real run shows main getting the wording wrong.
- **The gate is the question only:** facts go in the question text, each option's why in its description. No card above it, so `crucible-gate` v1 is `SKILL.md`, `gate.sh`, `gate.jq`, with no owed record and no stop hook.
- **Answer events only when the answer drives what happens next** (the review scope, a dispatch approval, a commit): the gate JSON carries an optional `record` name, and only then does the answer hook write `gate.<record>.answered` with the human's own answer. Every other gate leaves no event. A piece that needs the decision refuses without that event. Arrives with `crucible-events`/`crucible-effort`, not in v1.
- **Rich cards live with their owner, never in core:** the dispatch card with agent dispatch, the build/test/review cards with their flows. Only the shared relay machinery (show, owed record, stop hook), if still needed, is shared, and it moves out only when the first owner needs it.
- **The new framework's home:** `/Users/cordona/IdeaProjects/cordona/claude-code-crucible/new-rewrite/`, skills at `new-rewrite/framework/core/main-thread/crucible-<thing>/` (no `procedures/` level). First skill: `crucible-gate`.
- **Two kinds of cards (owner, 2026-11-21):** deterministic ones, computed from events and reports (agent dispatch, build, test and review reports, test plan challenge), are script-rendered and live with their owner; free ones are authored by main as it sees fit. A free card stays short, and the decisive facts go in the question itself, since the dialog can hide the text above it.
- **Question rules:** always built from the concrete scenario; always a recommended option first, with why; always open to the human's own words (AskUserQuestion's built-in "Other", never a fake option); help a context-switching human decide fast from facts and an honest, objective recommendation that never hides the honest alternative. The validator enforces the shape (2–4 options, the first marked recommended, a why on each); the prose carries the rest.

- **Main writes a small JSON per gate, computed from the situation:** `title`, `facts`, and 2–4 `options`, each with a `label` and a `why`, the recommended one first and marked.
- **`gate.sh`:**
  - checks it (2–4 options, the recommended one first, a `why` on each, short labels) and refuses with a plain reason;
  - renders the card;
  - builds the AskUserQuestion payload from the same file, so the card and the question never disagree, and a typed answer is always allowed;
  - inside an effort, the answer becomes a `gate.answered` event with the human's words.
- **Keep, proven live:** `open-gate.sh`, `gate-question-hook.sh` (refuses the question before the card is relayed), `gate-answer-hook.sh` (writes the answer event), and human-view's show-stop hook (the card must be in main's final message, verbatim).
  - **Why they exist:** main sometimes summarised, retyped or skipped the card before asking, and the AskUserQuestion dialog can hide that turn's earlier text. So the card is relayed as the turn's last message, then "now ask".
  - **Keep it:** it's an invariant in code, the failure (deciding blind) is the worst kind, and it costs no prose. It applies only to real gates with a card; plain quick questions need no hooks. A sandbox test without the hooks could show whether Opus 5.5 still needs them (optional).
- **Drop:** the twelve per-skill gate renderers, every fixed question file, and per-gate wording rules spread across skills.
- **Prose:** about ten lines of how: when a gate is worth it (decisions that matter and that main initiates: starting an effort, approving a plan, choosing fixes, dispatch, commit; otherwise act or ask in a plain sentence); how to build one (the recommendation first in good faith, facts on every option, at most four, plain words, never hide the honest alternative); keep the human thinking.
- **Invariant:** pieces that need approval (dispatch, commit) refuse without a matching answered gate.
- **Today's `procedure-approval-gate`:** `open-gate.sh` 1,719 words, `gate-question-hook.sh` 1,959, `gate-answer-hook.sh` 1,365, views 84, prose ~1,900 words (SKILL.md and `gate-failures.md`).

## The simplified effort

**As built (2026-11-21), superseding the older lines below:** small scripts, no hub: `effort-start.sh`, `effort-pause.sh`, `effort-resume.sh`, `effort-close.sh`, `effort-status.sh`, `effort-list.sh`, `effort-state.sh`, with one rule file per event in `crucible-effort/events/`, applied by `crucible-events/scripts/event-write.sh`.


**Settled 2026-11-21:**
- **Paused was re-added by the owner** (later the same day). The effort events are `effort.opened`, `effort.paused`, `effort.resumed` (from paused or closed) and `effort.closed`, each with the human's `words` except opened. See `specs/effort-events.md`.
- **The space stays `~/.crucible`**: the old rewrite only ever ran in sandboxes.
- **Events live only inside each effort's own `events/` folder**, never outside it: the four effort types above. The newest one is the state.
- **Small single-job scripts, no hub:** first the scripts, then lint, then run them; the prose comes after. No full spec: each script's `--help` is its contract.
- **The close refusal while work is open** waits until seats and grills exist.


Today's `procedure-effort`: about 4,400 prose words (SKILL.md 2,222; five references 1,705; six fixed question files ~490), three scripts (~6,850 words), six views. The owner: "a mess", "tons of code, gates and shit for something relatively rare".

- **States:** **open** and **closed** (closing records an outcome, done or dropped, and the human's words), with reopen allowed.
  - **Paused, dropped as a state:** it was added 2026-10-25 (`.crucible/docs/harness/runs/decisions/effort-lifecycle/report.md`, `proposal.md`) for "parked, coming back" and to bound metrics periods. An idle open effort covers the first; session boundaries and closing cover the second.
  - **The owner said** they don't remember why pause exists. Not yet explicitly confirmed: drop paused.
- **One script, `effort.sh`:** start, list, close, reopen, status.
  - keep `effort-state-validator.jq` and `effort-move-guard.jq` (right as they are);
  - add one refusal: `close` refuses while a seat is working or a grill is open, naming them (read from the effort's own events), and `--anyway` goes ahead on the human's go;
  - output is one plain line, with no rendered cards and no owed-card relay.
- **One gate,** only for starting an effort (main initiates, so the human must see why).
- **Everything else is conversation:**
  - "close it" from the human: main runs the script, no gate;
  - when the work looks done, main asks in a plain sentence or a quick question it builds;
  - "which effort?": list and ask;
  - status: the script prints it.
- **Prose:** about 100–150 words of judgment: when to offer, how to find, how to close when work is open, don't mix efforts in one session.
- **Drop:** `find-effort.md` (694 words), `state-change.md` (551), `state-offer.md` (323), `offer-failures.md` (137), the six question JSON files, `render-effort-offer.sh`, `render-effort-state.sh`, and most views.
- **Why the old prose grew:** exit-code handling (main can read stderr itself), pre-written questions and wording (main should compute them), rare-case branches, an invariant (open work before close) written as prose instead of a refusal, and cross-references to other files.

## Rules for writing the new framework (settled in discussion)

- **An example of a question is the AskUserQuestion JSON** that would ask it (owner, 2026-11-21): every question is a gate, so its example shows the real input, never a quoted sketch.

- **Prose names a folder, not its scripts** (owner, 2026-11-21): "the scripts are in `scripts/`, each `--help` is its contract". A list of scripts drifts when one is added or removed. The one exception is a script the prose tells main to run at a given moment.

- **No Never/Always sections:**
  - an invariant goes in its script, as a refusal;
  - a rule needed everywhere goes in core `CLAUDE.md`, once;
  - judgment goes as one sentence in the how where it applies;
  - anything else goes.
- **No exit-code tables in prose:** a script's `--help` is its contract, and main reads stderr.
- **No fixed question files:** main computes the question; `gate.sh` renders it.
- **No prose that references other prose files** (constitution value 15).
- **The old pattern to watch for:** independent actions turned into fake numbered steps (`procedure-effort` mixed a start sequence, a resume path and on-demand actions into one list of 11 steps).

## Proposed, not yet decided

- **Value 16, "weight follows frequency and stakes":** added to the constitution (2026-11-20).
- ~~Confirm dropping the paused state.~~ Settled: paused is kept.
- **The effort skill as a pilot** of the new style (invariants into the script, prose to a few lines, measured before and after). Offered; not answered.

## Earlier work in this session (paused, kept as quarry)

- **Review-flow specs** in `.crucible/docs/harness/runs/decisions/review-flow/spec-guide/`:
  - `01-decisions.md`;
  - `02-review-report.md`;
  - `03-test-plan-challenge.md`, which includes sealing (a plan is sealed once its tests are written; any later test change is a new, standalone plan with no back-reference) and option B (fix-round test repairs, approved by the four PS workers with conditions);
  - worker evidence in `02-verification/` and `03-verification/`.
- **Built, uncommitted:** the review-report scripts (`flow-code-review/scripts/` and reviewer-role changes in `procedure-seat-run`, `report.sh` rewritten in place, `dispatch-names.jq`, `prepare-agent-prompt.sh`, an `events.sh` guard change). 154 checks plus two blind checkers.
  - Results: `.crucible/docs/harness/runs/decisions/review-flow/build/review-report/results.md`, with a placement table.
  - Backups: `.crucible/backups/review-report-build-*`, `review-report-fix-*`, `review-report-move-*`.
- **Script map:** `.crucible/docs/harness/runs/decisions/rewrite-map/map.md`. 190 scripts by group; it lists duplication candidates (twelve gate renderers, 55 copies of `die()`/`printable()`, the two `cards-lib.sh`, write-scope pairs, seat titles built in three places) and the largest files.
- **The PS workers** (Dev Gamma [Core API], Dev Alpha [Eco API], Dev Epsilon [Auth API], Dev Beta [Backoffice]) were consulted directly by SendMessage for real-world evidence. They were useful at every round; keep at most two rounds per question.

## Settled 2026-11-21 (later)

- **The context layout is approved:** `<effort>/context/draft/{docs/,entries.json}` and `<effort>/context/v<N>/`. The context scripts are built and verified (`specs/context-analysis.md` §5); the prose isn't written yet.
- **The grill gets the same treatment:** `specs/grill-analysis.md`.
- **Fable reviews every design:** each strategy goes to the "Crucible Fable Reviwer" session before building. It judges against the constitution and the prompting guide: SRP, DRY, coupling and cohesion; composable pieces; avoidable dependencies; no over-prompting; determinism only where it's needed.
- **Grill decisions (owner, 2026-11-21):**
  - The shape is approved (`specs/grill-analysis.md` §6).
  - "Grill me" counts as the effort yes, with no separate offer.
  - Rounds are mini gates: a small card, then one AskUserQuestion. The card-before-every-question rule stays.
  - F6: the context's help and docs rule stop naming grills.

## STATUS (end of 2026-11-21): read this first after a compaction

**Built and verified by execution** (all under `new-rewrite/framework/core/main-thread/`; nothing committed, nothing deployed):

| Skill | Pieces | Prose |
|---|---|---|
| `crucible-events` | `scripts/event-write.sh` (the only writer; applies `<component>/events/<type>.jq`), `scripts/lib/lock.sh` (the shared lock) | none, by design |
| `crucible-gate` | `scripts/show-card.sh` (`--record --effort --subject --accept`), `scripts/gate-answer.sh` (the one reader: the newest answer counts), hooks `stop/require-card-shown.sh`, `pre-tool-use/hold-question-until-card-shown.sh`, `pre-tool-use/check-question-shape.sh`, `post-tool-use/record-gate-answer.sh`, `events/gate.answered.jq` | closed |
| `crucible-effort` | `effort-start/pause/resume/close/status/list/state.sh`, events `opened/paused/resumed/closed` | closed |
| `crucible-context` | `context-docs/add/drop/status/fingerprint/cut/verify/path-check.sh`, `lib/`, `events/context.cut.jq`; the cut refuses NOT-APPROVED unless `spec.md` is the newest approved spec | closed (Fable verified; the context rule lives only here, discovery trimmed to one line) |
| `crucible-grill` | `grill-new/add/answer/mark/show/end/list.sh`, `lib/grill-shape.jq`, `events/grill.ended.jq` | closed |
| `crucible-dynamic-flow` | `flow-agree` (requires a recorded yes), `flow-change` (add/skip/move/reopen/revise), `flow-step-done`, `flow-end`, `flow-show` (`--file` renders the agree card), `hooks/stop/remind-flow-position.sh` | closed |
| `crucible-spec` | `scripts/spec-approve.sh`, `events/spec.approved.jq` | closed |
| `crucible-discovery` | none (a how only) | closed |
| domain `new-rewrite/domains/software-development/core/main-thread/code-context/` | `context-add-commit.sh` | signpost `SKILL.md` |
| domain `.../main-thread/trackers/` | `tracker-read.sh` (GitHub/GitLab issue, read-only, body + comments), `context-add-ticket.sh` (copy into draft docs, header marks it quoted + partial) | signpost `SKILL.md`; closed (Fable accepted results) |

**Evidence** (run script + full output, each run from a neutral folder): `.crucible/docs/rewrite-next/evidence/`: `effort-run`, `context-run`, `grill-run`, `fixes-run`, `dynamic-flow-run`, `gate-answers-run`, `spec-run`, `tracker-run`, `lib-decide.sh` (one recorded gate through the real hooks). Specs: `.crucible/docs/rewrite-next/specs/` (`crucible-gate.md`, `effort-events.md`, `context-analysis.md`, `grill-analysis.md`, `dynamic-flow.md`, `gate-answers.md`, `crucible-spec.md`; drafts in `history/`).

**Next, in the owner's order:**
1. ~~Tracker reading~~ done: spec `specs/tracker-reading.md`, evidence `evidence/tracker-run`. Open for the owner before any deploy: the domain skills' names (`trackers`, `code-context`); Jira later as its own piece; logged-in GitLab comments unproven until the live run.
2. ~~The `crucible-context` prose~~ done (2026-11-21). Next: the follow-ups below, then the live run, which proves how main behaves with these skills and hooks.

**Core completeness review (Fable, 2026-11-21):** `reviews/core-completeness-review.md`. A1 done: core `new-rewrite/framework/core/CLAUDE.md` (owner's How-you-talk paragraphs verbatim, cadence paragraph, Never/Always with reasons; context-efficiency left out). Its "Never send agents" line has an end date: remove it with the dispatch build. A2, A3, B1, B2, C1 built on the owner's go (spec `specs/core-completeness-fixes.md`, evidence `evidence/fixes-run`): install in `new-rewrite/framework/core/install/` (each component declares its hooks in `hooks/matchers.json`), events mode 444, effort-close refuses on any component's `scripts/open-work.sh` output (flow and grill ship one), the Bash guard in `crucible-events/hooks/pre-tool-use/`, the gate's no-hook sentence.

**Recorded, not built (each waits for its trigger; from the completeness review):**
- C2 decisions before or outside an effort leave no proof: when `effort-start` or a commit outside an effort needs a recorded gate.
- C3 the agent's side (how an agent reads its context, the agent half of artifact hand-off, the grill-status note, a running agent getting a revised spec's path): with the dispatch build.
- C4 a commit piece that refuses without a recorded yes: with the VCS work; until then "never commit" is prose in core CLAUDE.md.
- C5 shared card rules: when a second script-printed card arrives.
- D1 metrics: one read-only script, count on demand, no harvest events; the one sanctioned transcript reader. When old-vs-new comparison is wanted.
- When the first domain component ships `open-work.sh`: effort-close finds it only in an installed layout (skill links make components siblings); say so in effort-close's --help and run that evidence from an installed layout.
- Live run, watch: with only part of the hooks installed (Stop missing, question hook present), the gate's "then ask" gets denied; the install check sorts it out.
- D2 pruning old efforts: when efforts pile up. D3 dashboard answers: when a real case shows up. D4 Jira and the domain skills' names: the owner's call.
- The four old skills: `standard-artifact-handoff` and `procedure-resume` live on as one line each in core CLAUDE.md (agent half with dispatch); `procedure-context-efficiency` left out (owner, 2026-11-21); `procedure-metrics` is D1. Don't port them by reflex.

**After those:** dispatch and spin-off (they run the cut; running agents get a revised spec's path); live runs (deferred by the owner until the context part is complete; then validate up to the point of dispatching agents).

**How we work (owner's rules):**
- **Scripts:** design → Fable reviews the design and its compliance → the owner's explicit go → build → run every case with full output from a neutral folder → Fable judges the results, never the implementation.
- **Prose:** standing go. Write it → Fable verifies it against the constitution and checklist 13 → apply the review → next.
- **Nothing is built without the owner's go;** Fable's "go" never counts. Never commit, push or deploy unasked.
- **Fable** is the "Crucible Fable Reviwer" session (SendMessage to its uds address). Every Fable result is shown to the owner here.
- **Writing rules:** no versions; no prose naming scripts, only the folder; a question example is AskUserQuestion JSON; every field has a named reader; one rule file per event; small single-job scripts with no hub; core is domain-agnostic.
- **Open owner question:** Fable's four success tests and the acceptance run. The owner took the "what is success" question to Fable directly.
- **Evidence gap closed (2026-11-21):** effort, context and grill runs rebuilt as repeatable evidence; Fable reran each three times, all outputs match. Rule for every run: take folders and paths from a script's stdout, never hide an output.
- **For the dispatch side:** a grill question's `answers` also holds notes ("Dropped: …", "Deferred: …"). How agents read a grill must say: read the status first; the last entry is the answer only when the question is settled.
