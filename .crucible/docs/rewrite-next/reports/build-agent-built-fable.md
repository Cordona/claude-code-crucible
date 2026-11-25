# The build agent's submission, built: Fable's judgement (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `build-agent-built-brief.md`. Not a go; the owner's go is the only go.

**What I did:**
- **Reran the proof myself** on a frozen copy of new-rewrite and of the evidence folder, in my own scratchpad, from `/`: 116 pass, 0 fail, the same as `run.out`.
- Read `run.sh`'s set-up, the event rules, the shared jq files, the stop hook's wrapper, the installer's diff, and the commit of case 5.
- **Not done:** I didn't read every step script or the validation rules line by line, and nothing ran with a real agent.

## Verdict

**The evidence shows what the spec promises, at the level it can.** Every case of `build-agent.md` section 8 is there and passes, the repair lines match word for word, and the tree is the agreed one with the owner's change. Of the six decisions I accept three, would change two, and one belongs to the loop's spec.

**Four things I'd settle before the next agent is built on this,** because each gets copied or built upon:

1. the job's `setup` is fixed to three required names;
2. the builder's event rule carries a copy of the job model;
3. a missing submission file is charged to the agent;
4. the hook searches every effort on every agent's stop.

## 1. Does the evidence show what the spec promises? (question 1)

**Yes for the scripts.** What I checked against the spec:

| Promise | Shown by |
|---|---|
| The seven steps in order, and the stop let through | 1a |
| The iteration counted once, per tree, and refused when wrong | 1a, 1b, the wrong-stamp case |
| A known failure needs no blocker | 2 |
| A blocked build: no commit, no `commit` field | 3 |
| One repair line per problem; the second refusal ends the job and keeps the tree | 4a, 4b |
| A fix: its own event, its fix round, the trailers | 5 |
| A sent-back finding can't be declined; a `cannot` blocker is accepted | 6a, 6b |
| A changed report is refused by the one view | 7 |
| A commit with no event is recovered from its trailer | 8 |
| The installer finds `agents/`, maps the new hook, refuses two components with one name | install |

**What this proof can't show, to say beside it:**
- **No real agent.** Each case feeds the hook a hand-made stop. That a real builder is held, reads the lines and repairs its report is still the lab's Stage B result, not this build's. It is the first thing the live check should show.
- **No two agents stopping at once.** The lab found a lost event under exactly that (Stage B, finding 1).
- **The jobs are written by the proof's own fixture,** as agreed, so nothing here says anything about the dispatch.

## 2. The six decisions (question 2)

| # | Decision | My view |
|---|---|---|
| 1 | A `fail` gate needs its `failing` list, not a note | **Accept.** It is the better rule, and the spec's examples already did it. Correct the spec's sentence. One word to add there: `failing` holds whatever failed, since a lint or a build can fail too, not only tests. |
| 2 | Two writers for the submission events | **Accept.** Recovery has to write the same event. The rule checks the same body either way, and `by` records which one it was. |
| 3 | The pin sources the core's `sha256.sh` | **Change.** I suggested the reuse, and it was the wrong advice: a component sourcing another component's lib is what new-rewrite's own convention rules out. Give `agent-jobs` one small script that hashes a report, and let the pin and the view both call it. That is better on its own merits too: the pin and its check must hash the same way, so they should share one script. |
| 4 | `git-commit` gained `--unsigned` | **Accept.** Fix the stale `--help` line now; in new-rewrite the help is the contract. |
| 5 | A new fix loop is known only by `sent_back` | **Settle in the loop's spec.** Until the fix choice is an event, a second fix choice continues the old count. When it is an event, a fix's dispatch should name its loop and the round should count inside that. Then `sent_back` goes back to meaning only what it says. Say in `build-agent.md` that the count is provisional. |
| 6 | Rules include a lib by a relative path, proven on jq 1.8.1 only | **Change, together with point 2 of section 3.** The framework says jq 1.6 or later, and no rule in new-rewrite included anything before this. Either prove it on 1.6, or have the event writer give each rule its search path, so a rule writes a plain include. The second is a small core change and the owner's go. |

## 3. Drift from the agreed tree and from the conventions (question 3)

**The tree is as agreed.** No dispatch script was built, `job-of.sh` is the one reader of a job's start, and the per-kind files and the shared shell lib are as the owner and I settled them. The steps sit directly in the hook-type folder by the owner's choice, and the proof checks that only the wrapper is registered.

**Four things in the design, in order of weight:**

1. **The job's `setup` is three required names.** The rule for `job.dispatched` demands `language`, `framework` and at least one `standards` entry. Two things follow:
   - it settles part of the dispatch that hasn't been talked through;
   - it doesn't fit every job: the proof's own shell fixture had to invent a framework (`posix-sh`) to pass.

   What we agreed was that the trailers copy the dispatch's own keys. So `setup` should be an open map of one-line values, and the hook prints whatever is there.

2. **The builder's rule carries its own copy of the job model.** `code-builder/scripts/lib/submitted.jq` works out a job's dispatch, its agent and whether it has finished. `agent-jobs/scripts/lib/jobs.jq` already does the same. Nothing in that file is about a builder: it checks that a submission's stamps match its job and that the report is pinned. A tester and a reviewer will need the identical check, so it will be copied twice more. It is copied because a rule can't reach another component's lib. That is the same wall as decision 6, and the same door opens both. Settle it before the next agent.

3. **A missing `<kind>-submission.json` is handed to the agent as a repair line.** The agent can't repair an install fault. It is held, held again, and the job ends as "gave up", which blames the agent and hides the cause. It should go to the human, as the hook's other faults do, and count as no refusal.

4. **The hook searches every effort for the stopping agent.** It runs on every sub-agent's stop in every session, ours or not, and greps all efforts' events each time. It is cheap today and grows with the number of efforts. The dispatch will know the session's effort; note it for that talk, and don't fix it now.

**Smaller:**
- **The hook fails open,** and tells the human. That is right, and it matches the other hooks. It leaves one state to name: a report pinned with nothing committed and no event. The hook says so in words; main's door will need to see it too.
- **The iteration is counted per tree by its path.** A worktree that is moved would start again at 1. Worth one line in the rule's comment, or count by the branch.
- **One changed report stops the whole view** of that effort. That is what I asked for. It should be said in the spec that it is the whole effort, not the one job.

## 4. Order I'd take

1. The three small changes: the `setup` map, the missing-file fault, the hashing script.
2. The owner's word on how a rule reaches a shared lib (decision 6 and point 2). It is a core change.
3. The first live check: one real builder, held once by a refused report, then accepted.
4. Then the next agent's slice.
