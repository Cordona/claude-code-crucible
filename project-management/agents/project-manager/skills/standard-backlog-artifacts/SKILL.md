---
name: standard-backlog-artifacts
description: The single definition of an EXCELLENT backlog artifact — the shared rubric the project-manager BUILDS to. Applies whenever a GitHub issue, user story, epic, task, bug, or spike is authored, structured, or refactored. Defines the artifact taxonomy (epic / story / task / bug / spike, each with what it MUST and MUST NOT contain), the decomposition & right-sizing rules (INVEST, vertical slicing, the epic-vs-story test), acceptance-criteria form (Given/When/Then), Definition of Ready / Definition of Done, and — the core differentiator — the AUDIENCE MATRIX: how the same work becomes a materially different artifact for an `agent` vs a `technical` / `non-technical` / `business` human, plus the layered `both` format. This is WHAT an excellent artifact looks like; it does NOT define the project-manager's working conduct, gates, or report envelope (those live in the agent body). Pull-request bodies are NOT here — that craft moved to `standard-git-pr` (git-operator's domain) when the PR lifecycle moved to development work.
---

# Standard: Backlog Artifacts

The **one** definition of an excellent backlog artifact. The `project-manager` builds to it. Excellence is **not exhaustiveness** — it is the *smallest* artifact that carries the *right work* to the *right audience*, at the *right altitude* (epic vs story vs task). Vagueness and mis-sized work are the default failures; every rule here exists to prevent them.

This skill defines **WHAT good looks like**. It does NOT define the agent's conduct, the creation/account gates, or the report envelope — those live in the agent body.

## Philosophy

- **Problem-first, never solution-first.** A request that arrives as a solution ("build a CSV exporter") is reframed to the problem and outcome ("analysts can't get their data out → they re-key it by hand → export it"). Ask *why* until the real need is visible, then let the solution follow.
- **Right altitude.** Every piece of work has a natural size — initiative → epic → story → task. Capturing it one level too high is unactionable; one level too low is noise. Naming the altitude correctly is the highest-value judgment. An *initiative* (above epic) has no artifact type of its own — capture it as a top-level parent epic.
- **Ceremony matched to stakes.** A one-line typo bug is a one-line bug. Do not wrap trivial work in epic ceremony; do not under-specify a load-bearing feature.

## The pre-authoring reflexes (a senior PM's defaults)

1. **Reframe to problem + outcome** before choosing a type.
2. **Right-size and decompose** — decide the altitude and, if it's an epic, the child breakdown. This is the signature move.
3. **Slice vertically** — each story is a thin end-to-end slice that ships observable value, never a horizontal layer ("the DB part", "the UI part").
4. **Write testable acceptance criteria** — Given/When/Then; this *is* the definition of done, not a vibe.
5. **State non-goals explicitly** — the "Out of scope" section is where scope creep dies.
6. **Name dependencies & sequencing** — what blocks what, what must land first, what a prerequisite spike must answer.
7. **Surface assumptions and risks** rather than burying them.
8. **Ask the one load-bearing question**, then proceed — don't interrogate, don't guess blindly.

## The artifact taxonomy — pick the right type

| Type | Purpose | MUST contain | MUST NOT be |
|------|---------|--------------|-------------|
| **Epic** | A large outcome delivered by several stories | Outcome/goal, the value, a child-story breakdown (task list), non-goals, success measure | A single deliverable dressed up; a bucket with no end state |
| **User story** | One thin, valuable, end-to-end slice | "As a … I want … so that …", acceptance criteria (Given/When/Then), non-goals, INVEST-clean | A horizontal layer; too big to finish in one iteration |
| **Task** | A concrete unit of work with no user-facing value on its own | Clear done-state, the context needed to do it | A story missing its "so that" (if it has user value, it's a story) |
| **Bug** | A defect in existing behavior | **Repro steps · expected · actual · environment/version**, severity | A feature request in disguise (reframe to a story) |
| **Spike** | A time-boxed investigation to remove uncertainty | The **question** to answer, a **time-box**, the **deliverable** (decision/doc/prototype) | Open-ended research with no exit condition |

## Decomposition & right-sizing

- **INVEST** — every story is **I**ndependent, **N**egotiable, **V**aluable, **E**stimable, **S**mall (fits one iteration), **T**estable. A story failing *Small* or *Independent* is usually an epic or two stories.
- **Vertical over horizontal.** Split so each slice is demoable on its own. "Filter by date" + "export current view" beats "build the query layer" + "build the UI".
- **The epic-vs-story test:** if it needs more than one vertical slice to deliver the outcome, or can't finish in one iteration, it's an **epic** — carve the children and link them. If the request names a solution spanning several capabilities, it's almost always an epic.
- **When it's really a bug vs a feature:** a bug is *existing behavior deviating from its spec*; a change to *intended* behavior is a story. Reframe rather than mislabel.

## Acceptance criteria (Given/When/Then)

State each criterion as **Given** [context] **When** [action] **Then** [observable outcome]. Unambiguous, verifiable, and collectively the definition of done. No "works well", no "handles errors gracefully" — name the error and the expected handling.

## Definition of Ready / Definition of Done

- **Ready** (before it enters a sprint): INVEST-clean, acceptance criteria present, dependencies known, non-goals stated, audience clear.
- **Done** (before it closes): all acceptance criteria met and demonstrable; not "code written".

---

## The AUDIENCE MATRIX (the core differentiator)

The same work becomes a **materially different artifact** depending on who reads it. The audience is a **required input** the orchestrator supplies — the agent never guesses it. The canonical value set — `agent` / `human` / `both`, the human register `technical` / `non-technical` / `business`, and the composite tokens in this matrix's first column — is defined once in `audience-register.schema.json` (deployed at `$HOME/.claude/crucible/contracts/audience-register.schema.json`; framework source: crucible/contracts/audience-register.schema.json), the single source of truth for the values; this matrix defines what each value *means* for the artifact. The naive model (a single technical→non-technical spectrum) is wrong: there are two orthogonal dimensions —

1. **Literacy** — can they parse code/architecture/jargon?
2. **Job** — do they **execute** the ticket, or **decide/approve/track** it?

"Business" is a *job* (a decider), not merely "less technical." That is why it is its own register and never folds into non-technical.

| Audience | Leads with | Acceptance criteria style | Context assumed | Jargon | Deliberately OMITS | Length |
|----------|-----------|---------------------------|-----------------|--------|--------------------|--------|
| **`agent`** (not human) | The task + full self-contained context | **Machine-checkable assertions** — exact expected states, file paths, commands | **None** — no tribal knowledge; every path, link, and precondition is explicit | Precise/technical | Nothing — over-specify; ambiguity is the enemy | Verbose, exhaustive |
| **`human:technical`** (executor) | Scope + intent | Given/When/Then, testable | Codebase familiarity; points to areas, not every line | Yes | Business framing; hand-holding | Tight |
| **`human:non-technical`** (executor) | The goal in plain words | Plain checklist — "done when …" | Domain, but **not** code | **None** | Architecture; implementation detail | Moderate, guided |
| **`human:business`** (**decider**) | **Outcome + value + impact** | Success = a **measurable outcome / KPI** | Strategy context, not implementation | Business terms | **All implementation**; steps | Short, punchy |
| **`both`** | Layered | A human section (in the chosen register) **+** an agent section (assertions) | Per each layer | Per each layer | Per each layer | Two clearly-separated blocks |

**The load-bearing distinctions:**
- **`non-technical` vs `business` is executor vs decider**, not "less technical vs least technical." A non-technical executor still *does the work* → needs steps + a done-state. A business decider *approves/prioritizes* → needs value + impact; give them steps and you wrote the wrong artifact.
- **`agent` is defined by self-containment**, not by being "very technical." Its failure mode is any assumed context; write it so a cold agent with only this artifact can complete the work.
- **`both`** is genuinely two layers — a human block for the reader plus a fully self-contained agent block — never a single blurred middle.

Default the *language* of a business artifact to jargon-free, but keep the value/impact framing that is the whole point of a decider's artifact.

**When an epic meets a business register**, the type ("MUST contain a child breakdown") and the audience ("omit implementation, stay short") pull apart. Resolve toward the decider: express the breakdown as **outcome-framed milestones** — what value lands, in what order — not an implementation task list, and **link** the detailed child stories rather than inlining them. Value and impact still lead.

---

## Leave out (the anti-pattern catalogue)

Solution-first framing (no problem/outcome) · horizontal slices · missing or untestable acceptance criteria ("works well") · no non-goals · an epic masquerading as a story (or the reverse) · a feature request filed as a bug · a spike with no time-box or deliverable · **wrong-audience calibration** (implementation detail in a business artifact; assumed context in an agent artifact; jargon at a non-technical reader) · gold-plating trivial work · fabricated estimates or priorities the user didn't ask for.

## Excellence checklist (self-check before handing back)

- [ ] The artifact is **problem/outcome-framed**, not solution-first.
- [ ] The **type and altitude** are right (epic vs story vs task vs bug vs spike); an epic has a child breakdown.
- [ ] Stories are **INVEST-clean** and sliced **vertically**.
- [ ] Acceptance criteria are **Given/When/Then** and testable; non-goals are stated.
- [ ] The artifact is tuned to the **declared audience/register** per the matrix — right leading content, right omissions, right jargon level.
- [ ] For `agent`: **fully self-contained** (paths, links, preconditions explicit; criteria machine-checkable).
- [ ] For `business`: **outcome/value/impact**, no implementation.
- [ ] Dependencies/sequencing and any load-bearing assumption are surfaced.
- [ ] Ceremony matches stakes — nothing gold-plated.

## Constraints (NEVER violate)

- Never author a solution-first artifact with no problem/outcome, or an untestable acceptance criterion.
- Never mislabel the type — reframe a feature-as-bug, split a story-that's-an-epic.
- Never mis-calibrate for the audience — no implementation in a business artifact, no assumed context in an agent artifact.
- Never invent priorities, estimates, or scope the user did not ask for; ask the one load-bearing question instead of guessing.

---
*Standard Version: 1.1 — the shared backlog-artifact rubric. Built to by the project-manager. Grounded in INVEST, vertical slicing, Given/When/Then acceptance criteria, and Diátaxis-style audience calibration. Tracker-agnostic — the creation mechanics live in the project-manager's `procedure-gh-issues` script (GitHub today; Jira later), never in this rubric. **Pull-request bodies moved to `standard-git-pr`** (git-operator's domain) along with the rest of the PR lifecycle. It does not define the project-manager's conduct, gates, or report envelope (the agent body).*
