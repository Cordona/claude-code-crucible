# Jobs, step 1: the job defined. Fable's review of the spec draft (2026-11-26)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** `specs/jobs-1-defined.md`. In `new-rewrite/`: the `gate.answered` rule, how `event-write.sh` finds and runs a type's rule, how `worktree-busy.sh` finds `busy.sh`, and the list of domains and of the software domain's `agent-jobs` events.

**Not done:** nothing was run. I did not read `show-card.sh`, the gate's hooks, or the other specs in `specs/`.

## Verdict

**Move 2 is right and I checked it:** `gate.answered` already carries `record` and `subject`, so the proposal's hash goes there and the core event doesn't change.

**Move 1 I would not make now.** It builds a core component for jobs, a frame rule, an opaque object and a lookup mechanism, to serve a second domain that doesn't exist. And the split costs something real: the checks that matter most stop running when the event is written.

**The owner's principle is met more simply by leaving jobs where they are,** in the software domain, with the core untouched.

| Move | Answer |
|---|---|
| 1. `job.defined`'s rule in core, `work` and a domain check beside it | **Not now.** Sections 1 and 2 |
| 2. The hash in `subject`, no `shown` | **Yes.** Section 3 |

## 1. What the split costs

**Today a job's rule checks everything, at the moment of writing.** The rule runs inside `event-write.sh`, under the lock, on the whole log. The iteration rule sits in it: "iteration must be 3, the next build on this tree". Nothing can be written that breaks it.

**After the split the core rule checks the frame only.** The tree, the loop, the range and the plugins are checked by `job-check.sh`, which runs at resolve, before the card. Between the card and the answer the log moves. Two proposals resolved side by side can both claim the next iteration on one tree, and both would be defined: the rule that runs at the write no longer looks inside `work`.

So the split takes the software checks out of the one place that is atomic, and puts them in a step that runs earlier and can go stale. Closing that needs the domain check to run again at define, under the lock, which the engine has no place for. That is the complex machinery this would grow.

**Three more signs that the frame is thin:**
- **"A declared kind" can't be checked by a core rule.** A rule is pure: it sees the event and the earlier events. The kinds are a data file in the domain. The rule could only read it by naming the domain.
- **The frame already holds software words.** `{gate, round}` is the fix loop, and "G is a fix-targets gate" is a check the draft gives to core. The draft's own test 5 (no software word in core) would fail on it.
- **`plugins` and `work` are both the domain's,** one at the top of the body and one in a box. That is the shape telling us the line between core and domain isn't found yet.

**The lookup is borrowed from a different case.** `busy.sh` is a vote: every component is asked and any one can say busy. "Check and fill" is a function with one right answer. Asked of every component, two domains would both fill. If it comes to that, the component that declares the kind is the one to ask.

## 2. The simpler way to the same principle

**Keep the whole job component in the software domain, as it is today.** `job.defined`'s one rule lives in `agent-jobs`, checks the frame and the software fields together, at the write. The core gains nothing and names nothing. "Core pure, software logic in the domain" holds exactly.

**Then `tree`, `range` and `loop` stay where draft 5 had them,** and the shape the owner approved doesn't change. No `work` box, no `job-check.sh`, no lookup.

**The owner made this call once already.** A core abstraction was reverted in October as too early, to wait for a second domain. There is one domain today. When a second one needs jobs, the frame can be lifted out of a rule that exists and works, with two real cases to draw the line from.

**If the owner wants jobs in core now anyway,** then three things first: the domain check runs at the write and not only at resolve; the loop's form leaves the core frame; and the kind is checked by its domain. I'd want to see that design before step 1 is built.

## 3. Move 2, and three details

**Confirmed.** `subject` is a free string today, `record` names the gate, and the rule takes no other field. `--record jobs --subject <sha256>` needs no change to the gate.

1. **Name the resolved file by its hash.** `job-define.sh --gate SEQ` gets a hash from the gate and has to find the file. If the file is `<sha256>.json`, the gate's `subject` is the lookup, no path is carried, and "changed after the card" becomes "no such file". The earlier `shown` held a path for this; the name can do it.
2. **Main carries the hash by hand** from resolve's output into the card's arguments. A slip is caught at define, safely, but it costs a round. One small script that takes the resolved file, works out the hash and calls the card removes the hand-carrying. It is also where the card's content will be rendered in a later step.
3. **Define checks the gate fully:** its `record` is the jobs record, it was accepted, and its `subject` matches. The draft lists the last two.

## 4. The rest of the draft

- **Pieces and outputs:** right. One act each, a result and what is still needed.
- **All or none, and one repair line per fault:** right, and proven in the runs.
- **`job-define.sh` with `--loop` and `--replaces`:** fine as one script; it is one act with three sources.
- **The card's content is deferred to a later step.** The stress run showed the human approving fix targets the card didn't list. Until that step lands, step 1's live validation shows a card with a path only. Say in the spec that this step alone is not what the human will use.

## 5. The validation

The five cases are right for what they cover. Two to add:

1. **The stale case.** Two proposals resolved, each with a build on the same tree. Define the first; define the second. The second must be refused with the iteration it should have. This is the case that tells whether the software checks run at the write.
2. **A rejected gate.** The human answers no; define refuses; nothing is written.

If jobs stay in the domain, drop case 5 and replace it with: the core components are unchanged by this step.

## 6. For the owner

One decision: **jobs stay in the software domain (my lean), or a job frame goes into core now.** Everything else in step 1 follows from it.
