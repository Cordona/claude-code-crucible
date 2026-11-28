# Report schemas, draft 1, with the workers' opinions: Fable's view (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `schemas-fable-brief.md`. Talking only; the owner's go is the only go.

**What I read:** the draft, the briefing, all five workers' answers, and Dev Beta's positions. **Not read:** specs 02 and 03, and `report-inventory.md`. Where I say "as 02 had it" I rely on the workers and the brief.

## In short

1. **The workers did their job well.** Three of their points are blockers the draft must fix: the commit, known failing tests, and locations outside the tree.
2. **Dev Beta's positions accept nearly everything, and that is the risk in draft 2.** Five workers on one company's PHP, Laravel and GitLab projects, each speaking from the old framework's habits, will together ask for the old framework's reports. About a third of the proposed additions have no reader.
3. **One test settles most of it,** and it is the draft's own rule 4, applied to values as well as fields: a field or an enum value exists only if a script or a card treats it differently. Everything else is text.
4. **One design question is bigger than the schema:** who settles a decline. The draft lets the fixer, the reviewer and the arbiter settle it between them. The owner's standing rule says the human does.

## 1. Commits (question 2)

**The position is right:** the stop check's commits are working commits on the effort's own branch in the job's worktree. They never land. What lands is made by the gated toolbelt, in the project's style, with the human's consent per operation.

**Where it belongs:** split it.
- This spec keeps only the working commit, as the way a job hands in its tree.
- The landing commit, its style, the ticket, the split into commits, ports to release branches and the MR body belong to the landing step's spec.

**Three things follow that the position doesn't yet say:**

- **Once working commits never land, most of section 10 has no reader.** Keep the subject and the `Job` and `Effort` trailers (recovery). Drop `Fixes`, `Declines` and `Plan`: the events hold them, and nobody reads them in a branch that is thrown away. For the same reason, don't put `decisions` in the working commit's body. The landing step builds the body and the MR text from the reports. That answers the two-against-two split: both sides want the decisions where the reviewer reads them, and that is the landing step's output.
- **Does a working commit need signing?** Signing with the developer's own key at every agent stop has no reader either, and it is what produces `signed: false` on cards. Sign what lands.
- **The owner should say it once, plainly:** a commit the stop check makes in the effort's own worktree is covered by the approval of the build, and is not "a commit" in the sense of the consent rule. All five workers read it as a breach. If the owner doesn't see it that way, the alternative is the one KPI names: the job hands in the tree as it is and nothing is committed until the human says so.

**Gamma's lost scratchpad** is a separate point: the effort folder is durable and not a scratchpad, and whatever must outlive the effort is written into the MR at landing.

## 2. The positions, theme by theme (question 1)

| # | Theme | My view |
|---|---|---|
| 2 | Gates | **Half.** See below. |
| 3 | Impact | **Agree, without `kind`.** Four workers, real cases, and the card shows it in full. No script treats a migration differently from a secret, so `{text, at?}` is enough. |
| 4 | `found` | **Agree:** never a value, a part of one, or its length. Two kinds are enough, because they are two different events: something that must not be there (a key, a host, customer data) and instruction-shaped text. The `text` says which sort. |
| 5 | Locations | **Agree.** `@where:path`, `relates_to` and findings with no `at` each have real cases from three or four workers. |
| 7 | Test plan | **Mostly.** See below. |
| 8 | Plan challenge | **Half.** See below. |
| 9 | Review | **Agree,** each one through the reader test. `out_of_scope` passes (the merge must not harvest it). `notes` passes thinly (the human, and the external reply). Stable handoff names are stamped by a script, which costs the agent nothing. |
| 11 | Foreign `comment` | **No.** See below. |
| 12 | Arbiter `ask` | **Depends on section 3.** |
| 13 | Text limits | **Agree.** And see section 5 on what a failed check costs. |
| 14 | Test report | **No to both.** See below. |
| 15 | Workflow | **Agree,** they are dispatch facts. |

**Gates.**
- **`where`: yes, as a short label,** so the same gate can be listed twice (backoffice runs tests on two PHP versions).
- **`ci` as a place: no.** A pipeline runs after a push, and a push comes after landing. A build job can't report it. A green pipeline is a later fact from the remote, with its own home.
- **A reason kind on `not_run`: no.** Nothing treats "no environment" differently from "skipped". The `note` says it.
- **Known failures: a real blocker, but the list must not be the agent's.** An agent that may call a failure "known" can excuse any failure. The list belongs to the project or to the human's approval, arrives in the job, and the stop check compares against it.
- **"Every gate the project has is listed": drop it for now.** Nothing can check it until project facts have a home. Until then the agent lists what it ran, with at least one gate.
- **The tester gets the same gates as the builder.** Agree.

**Test plan.**
- **`keeps`: yes,** five of five, and it is the one line that guards against weakened tests.
- **`covered_by` on a removal: yes.**
- **Fixtures and support: one list, not two** (`support[] {file, what}`). The challenger is the reader, and to the challenger a golden, a base class and a captured fixture are the same thing: something the tests will lean on.
- **`extend`: no.** One worker. It is a `modify` whose `keeps` says "every existing row".
- **`move` with `from` and `to`: no.** It is a `modify`; `keeps` and `why` say what moved.
- **The baseline: make it a gate entry,** the same shape as in the build report. One shape, not two.

**Plan challenge.**
- **A target that is a code line or a helper: yes.** It is what allows the most valuable challenge, a behaviour the plan missed.
- **Its own `challenge.submitted`: yes.** What follows a challenge (a rework) is not what follows a review (a merge). That is the rule I'd use everywhere: one event type per different next step.
- **`correct`, `merge`, `shrink`: no.** The planner reads the title and the why. The only thing a script does with `ask` is the old check that an `add` ends with a new test. `change` covers the three.
- **Restore that check** (Alpha noticed it was lost).

**Foreign `comment`.** Five of five said yes, but three said so as a guess with no real case. In a foreign review nobody fixes, so the comment is the whole product. Then the finding's text should be written for the author in the first place, and the human edits it at the comments gate. One text, not two.

**Test report.**
- **`checks`: no.** A full-suite run is a `test` gate that isn't narrowed, with its `where`. Mutation checking came from one worker; it can be a gate name when a second project uses it.
- **`repairs`: no.** The plan already says which tests are modified and which are added. A script counts them.

## 3. Fix answers, and who settles a decline (question 3)

**Three answers, not four.**
- `done`, with an optional note: yes.
- `partly`, with a reason: yes. Otherwise a fixer that covered one place of two must pick the less false of two answers.
- `declined`, with a reason: yes.
- **`deferred`: no.** In every example the workers give, the human decided to defer. A fixer that sends a chosen finding to a follow-up ticket is overriding the human's choice. From the fixer it is a decline whose reason says "valid, not this change". The follow-up is what the human may then choose.

**The human-chosen decline rule is right, and it reaches further than the brief says.** In the job model every finding in a fix job was chosen by the human. So every decline is a decline of a chosen item, and by the owner's standing rule only the human waives it.

That collides with the draft's sections 5 and 6, where a reviewer's `withdrawn` or an arbiter's `drop` settles a decline with nobody asked. Two workers saw this. It can be kept unattended and still honest:

- a declined finding is set aside and the loop goes on with the rest;
- the reviewer still answers it, but as a view for the human (agrees, or doesn't, with one line);
- the end card shows each decline with both views, and the human waives or insists.

**Then the arbiter is no longer an owed round inside the loop.** It becomes something main can offer the human who wants a third view before deciding. That removes a round, and the `ask` ruling with it: every ruling is advice and the human decides. This is the owner's call, since the arbiter round is in the earlier specs and ran in the lab. My recommendation is the simpler form.

## 4. External review (question 4)

**Six is the right set, and it should be the ceiling.** Each differs in what follows it: a fix (`valid`), a reply that disagrees (`rejected`), a reply that points at a commit (`already-fixed`), a reply and a follow-up (`deferred`), a reply to a question (`answered`), nothing (`noted`). Folding `intended` into `rejected` is right.

- **`deferred` is a proposal here too.** The human sees it at the replies gate before anything is posted.
- **Per item within a thread: yes,** four workers, with the bot's own label as `item`.
- **A reply of up to a short paragraph: yes.** It is the one text written for an outside reader.
- **`source` stamped by a script, the description as a thread, relayed comments as a first review: yes.**

## 5. What the workers raised that the brief misses (question 5)

- **A failed check costs the whole job.** Rule 0.2: after two held stops the job ends and the work is not submitted. Alpha had plan edits refused for length five times. A report that won't validate should never throw away a finished tree: the work stays in the worktree and the next job starts from it.
- **Realism is the reviewer's guess.** Alpha's edge-case HIGH wasn't picked, came back from the outside review as real, and was fixed. No schema change, but the cards must keep showing edge cases in their own section.
- **One commit per job loses the atomic split** (Epsilon), and **ports to release branches** (Gamma). Both belong to the landing step; neither is in the brief.
- **Tenant data in any report text** (KPI). No check can catch it. It is one line of prose for the agents.
- **Never used:** the `questions` cap of 8, and `request_unclear` on one project. Drop the cap.

**And one caution on the brief's own lesson,** "draft 2 should start from 02 and 03". Those specs belong to the rewrite the owner set aside for saying too much. Restore from them a point at a time: only what a worker showed a real case for, and only if it has a reader. Remember too that every field and every value kept becomes a line an agent must be taught.

## 6. Before draft 2

1. The owner's word on the working commit (section 1).
2. The owner's word on who settles a decline, and so on the arbiter (section 3).
3. Then draft 2, with the reader test applied to every value.
