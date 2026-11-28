# The job event shapes, draft 3: weaknesses. Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go, and the owner approves every JSON shape.

**What I read:** `spikes/dispatch/job-event-shapes.md` (draft 3). In `new-rewrite/`, today's `job.dispatched` rule and the iteration rule (`agent-jobs/events/job.dispatched.jq`, `agent-jobs/scripts/lib/iteration.jq`), the header of `flow.agreed` and `flow.step.done`, and the one line that builds `gate.answered`'s body.

**Not done:** nothing was run. I did not read the gate's scripts, the flow's replay, or the step definitions in the core, so where I say what they hold today I say only what those few lines show.

## Verdict

**The model is sound and my draft 1 corrections are applied.** A gate per step, with jobs proposed from what exists then, removes the problem of inputs that don't exist yet. It also gives the fix loop an identity it didn't have: today's rule says "a loop is the human's fix choice, which has no event yet".

**Eight weaknesses, four of them serious.** None breaks the model. Each serious one is a place where the paper trail says more than what happened, or where the human approved less than what was written.

| | Weakness | Weight |
|---|---|---|
| 1 | The human approves the proposal; the event holds more than the proposal | Serious |
| 2 | `loop: true` lets any job through | Serious |
| 3 | A defined job that will never start can't be closed | Serious |
| 4 | A hot job is recorded as assigned before the message is sent | Serious |
| 5 | "Only four invariants" leaves out three refusals main will meet | State it |
| 6 | Filling inputs by kind is where the complex script would grow | Watch |
| 7 | `gate.answered` pointing to a proposal changes a core shape | Owner's eye |
| 8 | Smaller points | Small |

## 1. What the human approved, and what was written

The proposal holds kind, plugins, tree and a lens. After approval a script adds the range, the latest context, spec and grills, and the loop numbers. Two gaps follow:

- **The human never saw what was added.** "The latest" is also read after the approval, so a context cut made while the gate was open ends up in a job the human approved without it.
- **The proposal is a file kept in the effort.** Nothing says the file read at definition is the one the card showed.

**One change closes both:** fill before the card, not after the answer. A script resolves the proposal into full jobs; the card shows those; the gate's record keeps them; at approval `job.defined` is written from that record and adds nothing. The script after the approval then has no logic at all.

## 2. The fix loop exception

`{gate, loop: true}` says a job belongs to a loop. Invariant 1 is then met by any job that names that gate: any kind, any findings, any number of rounds. As drafted the exception is the one unattended stretch and also the one with no bound.

**Three things bound it, all simple:**
- **Content:** every job of a later round is a fix whose findings are among those the human chose at that gate, or a review judging those again. That is a subset check against the first round's job.
- **Length:** the round cap, as the rule has it today. At the cap the script refuses and says a gate is needed.
- **Turn:** the earlier round's reviews are in. The draft has this one.

**Who picks a later round's jobs isn't said.** If main does, it is the same proposal shape, accepted under the loop's gate when it passes the three checks, with no card. If a script works them out from the reports, that is real logic and I would not put it there.

**The gate can now be the loop's key.** Today rounds are counted per kind because the loop has no event. With the gate as the loop, `approved` can read `{gate, round: 2}`: a number where the draft has a flag, and the per-kind count goes.

**Two fields are called loop:** `approved.loop` and the top-level `loop`. With `round` in `approved` only one is left.

## 3. A defined job that never starts

Jobs are defined at approval, all at once. That makes an owed job visible, which is the gain. But main may drop one: the human changes their mind, or the first review makes the third pointless. The draft says starting over is main's. Then a job stays defined and unassigned for good, and the effort can never show complete.

**It needs one act:** a script that ends an unassigned job with the reason in a line. If today's `job.ended` can already do that for a job with no agent, say so; if not, this is the gap.

## 4. The hot assignment

The table has the door write `job.assigned` for a hot job. The door runs before main sends the message. If main doesn't send it, or the send fails, the log holds an assignment that never happened.

For a cold start the event is written when the agent starts, which is a fact. Keep the same standard for hot: the step after the message was sent writes it, as the split probe had it. The door only checks the hot rule and prints.

## 5. The invariants are seven, not four

The four listed are the right ones for the paper trail. Main will also be refused in three more cases, all already designed:
- more than one job agent in a reply;
- a start that isn't the call the door printed;
- a hot job for an agent with another base or missing plugins.

That is not a rule nest: each is one mechanical refusal, and none tells main an order. But the owner asked exactly this question, so the section should list all seven and not say "only".

## 6. Filling by kind

"The script fills what follows from the log" needs to know, per kind, which inputs a job takes: a review takes a range, a fix takes findings, and so on. Written as code, that is the old prompt builder coming back, and each new kind edits the script.

**Keep it as data.** The core already declares each step (`does`, `skills`, `ends_with`). Which inputs a kind takes by default belongs there, and the script reads it and names no kind. Today's rule says the same about itself: it checks shapes, and which job needs what is not its business.

## 7. The gate

`gate.answered` holds `{accept, answer, accepted}` today. "Points to the proposal" adds a field to an event of the framework's core, for a need of one domain. If it is added, it should be generic (what the card showed, by path), so the gate learns nothing about jobs. It is a sixth shape for the owner.

**Also say that an answer approves the whole proposal or none of it.** A changed proposal is a new card.

## 8. Smaller points

- **Define all or none.** "Every approved job at once" should mean that one wrong job stops all of them. Half a proposal defined is harder to repair than none.
- **A replacement's content.** `{replaces: N}` doesn't say what may differ from job N. If the script copies the job and only the agent is new, it is safe and simple. If main may change kind or plugins, it is an unapproved job. The one open choice is the tree: continue in the old one or cut anew.
- **The iteration rule's key changes.** Today it counts by the tree's path in `job.dispatched`. The path is now in `tree.cut`, so it counts by the job that cut. "Computed by the rule, as today" hides a rewrite of that rule.
- **Where `base` comes from.** The start hook gets the type's name and must not read meaning from it. The script that writes the agent file should record the base where the hook can read it.
- **`lens` and `standards`.** In the example the lens is always the job's one standard. If that always holds, one of them goes.
- **The door for several jobs.** Three reviews cost main: proposal, card, define, then door and start three times. If the door prints the calls for every ready job in one run, main still sends one per reply and saves two calls.
- **What ends a step with three jobs.** A step ends with one event today. "Every job of gate 41 ended" is a reading of the log and needs no new event, but the flow has to be able to ask it.
- **One repo "for now".** It contradicts the owner's own model of a tree per repo, on purpose. A `repo` field can be added later without breaking these shapes; the owner should see that it was left out.

## 9. The owner's three questions, answered

- **As mechanical as possible:** yes, and point 1 makes it more so, since the script after the approval then decides nothing.
- **Agile and adaptive, no rule nest:** yes, with points 3 and 5. Without a way to drop a defined job, adapting leaves the log wrong.
- **No complex script logic:** two places would grow it: filling by kind (6) and working out a fix round's jobs (2). Both have a plain alternative.

## 10. Before the stress test

1. Fill before the card; define from the gate's record (1).
2. Bound the loop; `{gate, round}` (2).
3. The act that ends an unassigned job (3).
4. The hot assignment after the send (4).
5. The six shapes as one example chain, to the owner: the proposal, the gate's added field, and the four events.
