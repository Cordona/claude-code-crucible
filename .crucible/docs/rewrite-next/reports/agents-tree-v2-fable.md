# The agents tree, version 2: Fable's view (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `agents-tree-proposal.md` version 2. Design only. Talking only; the owner's go is the only go.

**What I read:** the proposal, the constitution, and in new-rewrite the shared steps, `trailers.sh`, `stamps.jq`, and `agent-jobs`' rules and libs. I ran nothing.

## Verdict

**Yes, it is right by the constitution, and the tree is clear.** I had argued for sharing the rules; the owner's rule is the better reading of the success criterion, which asks for loosely coupled pieces before it asks for no repetition.

**The rule needs one sentence more to be exact,** because the plumbing does read two things in a report today. And two places in `agent-jobs` still list what belongs to the agents.

| # | Point | What I'd do |
|---|---|---|
| 1 | The plumbing reads `at` and `summary` | name them as the plumbing's own contract, and keep them |
| 2 | "ALL rules" in every file means six copies | copy between agents; share inside one agent |
| 3 | `agent-jobs` would list the two fix kinds | tell a fix by what the job carries, not by its name |
| 4 | The job's start rule lists the agents' fields | for the dispatch talk, as already agreed |

## 1. Is it right by the constitution?

**Yes.** Section 11 pulls both ways: reuse before adding, and each piece with its owner. For rules about a report's content the owner is the agent. A shared rules file means one agent's change can break the other, which is the coupling the owner names.

**What it costs, so it is said:**
- `report-schemas.md` section 0 states rules for every report: one line of text, the form of a location, the shape of a gate. Those now live in each agent's copy, and the copies can drift.
- The readers of every report (the cards, main's door) rely on those shapes being the same.
- **The guard is the proofs, not shared code.** Each reader's proof should read a real report from each agent. I wouldn't add more than that.

## 2. Does `agent-submission` still read content? (question 2)

**Two things, both needed by the plumbing itself:**

| What it reads | Where | Why |
|---|---|---|
| every `at` in the report | `report-check.sh` | it looks up each file in the tree and counts its lines, before any rule runs. So the form of a location is known to the plumbing |
| `summary` | `working-commit.sh`, through `trailers.sh` | the commit's subject |

It also prunes empty lists and requires one JSON object, which is about form, not content.

**I'd keep both and say so.** "Reads no report's content" isn't quite true and can't be: the plumbing needs a small contract with every agent. State it in one place:

- a report is one JSON object;
- any `at` in it is a location;
- a report whose job commits has a `summary`.

Everything else in a report is the agent's. Then the rule is exact, and a reader knows where the line is.

**Three leftovers to clear when it is built:**
- `report-check.sh`'s help still gives a shared rules module as its example;
- `trailers.sh` and `git-commit`'s help list the kinds by name (`build`, `fix`, `test`). The subject should take whatever kind the job has, so a new kind edits neither;
- `stamps.jq` is right as it is: it reads only the job.

## 3. Copies between agents, not inside one

The tree marks every rules file "ALL rules". Taken literally that is six full copies of the same text, location and gate rules: two in the builder, four in the tester.

The owner's rule is about coupling between agents. Inside one agent there is one owner, so nothing is coupled. The proposal already allows an agent's own common lib; I'd make it the norm:

- `code-builder`: a build-fix report is the build report plus the answers;
- `code-tester`: a plan update is the plan plus its answers; a test-fix report is the test report plus the answers.

That leaves two copies of the shared ground, one per agent, which is the price the owner chose.

## 4. Is `agent-jobs` coupling the agents? (question 3)

**Mostly no.** These are right as they are:

| Piece | Why it isn't coupling |
|---|---|
| `jobs.jq`'s check of a submission's body, which every agent's event rule calls | it checks the stamps and the pin against the job. It reads nothing an agent wrote |
| `iteration.jq` knowing the kind `build` | "an iteration starts at a build" is the job model itself |
| the view and the pin | they take any event that pins a report, with no list of types |
| `tester-facts.sh` naming the builder's kinds | agents may know each other's events. That is the allowed way |

**Two places still list what belongs to the agents:**

1. **"Is this a fix?" by name.** I suggested one function that knows `build-fix` and `test-fix`. Under the owner's rule that is `agent-jobs` naming both agents' kinds, and a third agent that fixes would edit it. Better: **a fix is a job that carries the findings the human chose.** That is a fact in the job, with no name in it. The round still counts per kind.
2. **The job's start rule lists the fields a job may carry:** `findings`, `sent_back`, `plan`, `challenges`, `words`. Only their shapes are checked now, which was the right step back. A reviewer's job will still mean editing that list. It is already noted for the dispatch talk, and I'd leave it there.

## 5. The proof's new check

"No agent's file names another agent" is a good check to keep. Two notes:
- naming another agent's **event or kind** must stay allowed, or `tester-facts.sh` fails it;
- add the other direction: nothing in `agent-submission` or `agent-jobs` names an agent or one of its kinds, except `build`.
