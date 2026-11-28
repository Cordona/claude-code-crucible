# The build agent, two mechanics changes: Fable's view (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `build-agent-fable-brief.md`, `build-agent.md` and `decisions.md`. I ran nothing and did not read the new-rewrite event writer.

## Verdict

1. **Configuration trailers: fine, as a copy for the human to read.** They pass only on that one reader. Take them from the dispatch as it names them, and let no script ever read them.
2. **The slim event: yes. The owner is right, and it is the same argument I made against `files`.** It needs three conditions to stay simpler than what it replaces.
3. **Before building:** the `Job` trailer should carry the seq, and four small things.

## 1. Configuration trailers

**The reader test, honestly:**

| Reader named | Real? |
|---|---|
| The human in `git log` | Yes. It is the owner's own wish, and the only reader that holds. |
| The landing step | I don't see it. It writes in the project's style from the project's template. |
| Comparing outcomes by setup | That reads the events (the dispatch joined with the answers), not git. |

So this is a second copy of facts whose home is `job.dispatched`. It is a harmless one: stamped once from an event that never changes, on a commit that never lands. What I'd ask for:

- **Say what it is:** a copy for reading. No script reads these trailers. Anything that compares setups reads the events.
- **Use the dispatch's own names.** `Language`, `Framework` and `Standards` are one domain's plugin kinds. If the trailer set is defined here, it becomes a second list to keep in step. Stamp whatever keys the dispatch holds.
- **`Model`:** include it if the dispatch already records it, like any other key. Don't add a field to the dispatch for the trailer's sake.

## 2. The slim event

**Why the owner is right.** In draft 3 the report is already a trusted source that nothing pins. The card reads it, the reviewers get the builder's decisions from it, the re-reviewer gets the fixer's reasons from it. If that file changed after the stop check, all of those would be wrong today and nothing would notice. So:

- **the hash is worth having whatever happens to the extracts.** It closes a real hole;
- **once the report is pinned, the extracts are a second home** for facts it holds. That is what I said about `files` and the commit.

A side gain: every submission event gets one shape, so the spec's many "Event" sections become one.

**Three conditions.**

1. **One place opens and checks the report, not every reader.** "Each checks the hash first" puts the same step in `next.sh`, the round, the merge and the cards. Put it in the one script that already turns the log into what the others read (the view). It joins each pinned report to its event and refuses on a mismatch. The rules that decide then stay what the lab proved: rules over one joined view, testable from fixtures.
2. **Whatever a script stamps must be in the report before it is hashed.** Finding IDs, challenge keys and the thread's source were stamped into the event until now. With a slim event they have no other home. So the stop hook adds them to the validated report, then hashes it. Rule 0.3 needs one more sentence for that: the agent may not write those keys; the hook does.
3. **Events written by scripts keep their full bodies.** A merge, a fix choice or an opened round has no report behind it. The event is its only home. The slim shape is for what an agent hands in.

**The question about rules under the lock.** In the builder's slice I see none that needs an extract: `red`, `blocked` and the security count are read by the scan, and the fixer's answers by the round and the merge. None of those runs inside the event writer. Dev Beta knows the writer's rules and I don't: if one of them checks a new event against what an earlier submission said (a merge against the reviewers' findings, say), it needs the joined view under the lock, or that one extract stays. Name any such rule in the spec; don't keep extracts just in case.

**What it costs, so it is said:**
- the rule cases need report files beside their events;
- one new way to fail: a report changed after it was handed in. One refusal line, told to the human. It should be rare;
- read-only is a fence and the hash is the pin. Keep both, but don't lean on the first.

## 3. Before it is built

1. **The `Job` trailer should carry the seq.** Recovery matches a commit to a job, and the seq is the job's key in the events. The readable name comes from the kind and the agent, and a builder reused for two fixes would give the same name twice. Put the seq first; the name can follow it on the same line for the human.
2. **`job` and `agent` in the body: agree.** The core writer shouldn't learn what a job is. The view derives the root and the round from the job's dispatch.
3. **A sent-back finding the fixer can't do** is told to "add a `request_unclear` blocker". That is the wrong word for it: the request is clear. Only `gate_red` is treated differently (it pairs with a gate). Give the other kind a neutral name that covers both cases.
4. **Say what the event holds when the tree didn't change** (a blocked build, or a fix that declines everything): no commit, so no `commit`.
5. **The order of the stop hook with the hash:** validate, stamp, hash and make read-only, commit, write the event.
6. **Two more cases to show when it is built:** a report changed after submission is refused; a commit whose event is missing is found again by its trailer.
