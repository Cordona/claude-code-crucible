# The job event shapes. Fable's review (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go, and the owner approves every JSON shape.

**What I read:** `spikes/dispatch/job-event-shapes.md`.

**Not done:** nothing was run. I did not put the draft beside today's `job.dispatched` in `new-rewrite/`, or beside the flow and gate events; where I ask how a job links to the approved plan, I don't know what those events already hold.

## Verdict

**The chain is right: what, where, who, then the link.** Each event says one thing, the agent is no longer part of the job, and a job traces to the human's answer. That is the owner's talk in shape.

**Not yet ready for the owner.** Two questions have to be answered first, because the shapes change with the answer (section 1). Then seven corrections, all small (section 2).

## 1. Two questions the draft doesn't answer

### 1.1 When is `job.defined` written

The name says "at approval". The fields say "at dispatch": a review's `range.head`, `findings`, `sent_back` and `earlier` don't exist when the human approves the jobs.

- **If it is written when the door runs for that job,** the shape works as drafted. Then say so, and the name "defined" is a little off, though I'd keep it.
- **If it is written at approval,** the inputs known only later can't be in it, and a second event would be needed. I would not go there.

**With the first answer one thing is missing.** `approved: {gate: 41}` says which answer, not which of the jobs that answer approved. If the gate approved three builds and two were defined, nothing shows the third is owed. The owner's criterion is that flows are tracked for completeness. If the approved plan already gives each job an id or a step, `approved` should carry it. If it doesn't, that is the gap to show the owner.

**Also say what a loop's later jobs point to.** A second fix round is not gated and replaces nothing. I assume it points to the gate that approved the loop; the table should say it.

### 1.2 What `tree` means for a job that changes nothing

The example is a review with `tree: {of: 12}`. Open point 2 speaks of a treeless reviewer. Both can't be the rule.

**One meaning, I suggest:** `tree` is where the agent stands. A reviewer with `of: 12` starts in job 12's tree and the write step keeps it from changing anything. A job with no `tree` field is one that isn't on code. Then "treeless" means only that, and the table's "a job on code" is exact.

**And `of` names a job that cut a tree,** never a job that itself has `of`. One hop, always.

## 2. Corrections

1. **`agent` means two things.** In `job.defined` it is a base agent's name; in the other two events it is an agent's id. Keep `agent` for the id. For the name: if the kind decides the base agent, drop the field, since the human approves jobs and not agents. If it doesn't, call it `base`.
2. **`agent.initialized` needs the base agent too.** The hot rule compares plugins, and plugins alone don't always tell a tester from a builder. Add `base`, and state the rule as: same base, and the agent's plugins cover the job's. Nothing should read it out of the `type` name.
3. **The examples should be one chain.** The job asks for the security standard; the agent in the example has no standards skill and its type name has none. A reader takes that for a rule.
4. **`from` has three forms, one a bare string.** Make them one form: `{"ref": "origin/main"}`, `{"pr": 41}`, `{"commits": […]}`. And say what a tree cut from several commits is. If no job needs it today, leave it out until one does.
5. **A tree has a repo.** The owner's model is one job, one tree, one repo, with other repos added read-only. Neither the job nor `tree.cut` names a repo or the extra folders. For one repo that is fine. The shape should show where they go, or say an effort is one repo for now.
6. **Three fields repeat what is already there:**
   - `tree.cut.from` repeats the job's; the `job` link and `commit` are enough.
   - `job.assigned.session` repeats the envelope's `claude_session_id`, unless they can differ. If they can, say when.
   - `job.assigned.name` follows from kind and job. Keep it only if a script reads it.

   `job.assigned.tree` also follows from the job, but the owner asked for that link by name. Keep it.
7. **`known_failures` is an input.** Put it in `inputs`, optional like the rest. "Always, may be empty" is a field every job carries for the sake of a few.

## 3. The three open points

1. **Pairing at the start:** the note and one job agent per reply, as proven. Nothing new in the shapes.
2. **One writer for `job.assigned` on a cold start.** The start hook fires for every cold agent, with or without a tree, and holds the agent's id. Let it write the event always. The tree hook then only answers with the path. That is one writer instead of two, and the A/B arm showed the start hook can do it. A hot job's assignment stays where it is.
3. **The mapping from `plugins` to skill names:** the door's, one place, yes. The hot rule in 2.2 uses the same mapping, so it must be one script both call.

## 4. One cost to state

Main now cuts the tree, runs the door and starts the agent: three calls for a cold job on code. It is the price of one script per act, and a tree that exists before the agent does is worth it. The stress test should count main's calls per job, so the owner sees the number.

## 5. Before the stress test

1. Answer 1.1 and 1.2.
2. Apply section 2.
3. The four shapes, as one consistent example chain, to the owner.

## 6. Added after the draft grew: "Who writes what"

**The split is right.** Main judges the proposal and sends what the door prints; scripts and hooks write every event. That is the owner's criterion, and thin prose follows from it.

**It answers 1.1 one way and so sharpens it.** The section says `job.defined` is written from the approved proposal, one per approved job. That makes an owed job visible: defined and not assigned. It also means the event is written before some of its inputs exist (a review's `range.head`, the `findings` of a job not yet run), and before a loop's later jobs are known at all. One of two has to be chosen:

- **Define at approval.** Inputs not yet known are named by the job they come from, and the door resolves them at the start. Then say where the resolved values are recorded, or accept that they are not.
- **Define when the job is ready to start.** Every value is real. The approved proposal is the list of what is owed, and `approved` names the proposal's entry.

I lean to the second: one event with real values, and the list the human approved stays the measure. Either way it is the owner's choice, and the shapes differ.

**Five points on the table:**

1. **The proposal is a fifth shape, and it isn't in the draft.** It is the one JSON main writes, the human approves it, and `job.defined` is built from it. It goes to the owner with the other four.
2. **Hot or cold is not part of what the human approves.** It is decided at the start, from which agents are alive. Keep it as an argument to the door, outside the proposal, or the human is approving agents again.
3. **Writing the agent files is its own script.** "The same step" as the gate card should mean it is called there, not that the card's script writes them. Files for a proposal the human rejects stay behind; accept that.
4. **One writer for `job.assigned` on a cold start,** as in section 3: the start hook, always.
5. **"Each prints the next step" should mean a result and what it now needs,** such as "job 12 defined; its tree isn't cut". A script that prints the next command of a fixed sequence is a pipeline in pieces.

**The call count grows.** A cold job on code is now: define, cut, door, start. The first two can take every ready job in one call; the start can't. The stress test should report main's calls per job for one job and for twelve.
