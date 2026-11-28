# The slow write guard and the index proposal: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** Dev Beta's message with the times and the proposal, against `write-scope.sh`, `agent-job.sh` and `job-of.sh` as I read them in my last two reviews.

**Not done:** I ran nothing and did not open the matrix's timing data. I have no breakdown of where the 700 ms goes, so section 2 asks for one before anything is built.

## Verdict

**The slowness is real and worth fixing. I'd not build the index as proposed.** It makes a second record of a fact that five scripts would have to keep in step, one of which isn't built yet. There is a smaller fix with one writer and no way to go stale, and before either I'd measure, because the number was taken under three times the load the framework will ever see.

| Question | Answer |
|---|---|
| 1. A cache file beside the events, or another way | **Another way: a note the reader keeps for itself,** section 3 |
| 2. Who writes and removes the index | **Nobody but the script that reads it.** That is the point of the change |
| 3. Is fall-back-and-check enough for a stale index | **With my version the question goes away:** it can't be stale |

## 1. What is wrong with the index as proposed

- **Five writers for one fact.** The dispatch would write it. The stop hook, the no-stop writer, the script that ends a job by hand, and the script that finishes a stalled job would each have to remove it. Miss one and the file is wrong. That is the coupling the owner has ruled out twice.
- **The dispatch isn't built,** and the owner wants to talk it through first. This would fix part of its design from the side.
- **A stale file is not harmless here.** After a job is handed in, an agent that wakes up again has no open job, so the hook gives no answer and Claude Code asks before any further write. That is today's protection against edits after the hand-in, which nobody reviews. A stale index would allow them.
- **Checking the index against the log** to be safe means reading the effort's log again, which is most of the cost the index was meant to save.

## 2. Measure first

**The times were taken with up to 36 agents running at once.** In real use the heavy writers are builders and testers, a few at a time. Twelve reviewers run together, and each writes once. So the number that matters is the time one agent feels with one to twelve running, and I'd expect it to be a good deal lower.

**Ask the data two things:**
1. the median for a Write with one agent, and with twelve;
2. where the time goes: the search over every effort, the read of one effort's log, and the many small `jq` calls in the step itself. I count about ten of those, and under load each one is slow.

**The bar I'd use for a write:** about 0.3 s in real use. An edit already takes the model several seconds, so that is not felt.

## 3. The fixes, smallest first

1. **One `jq` call in place of ten.** The step reads the job's kind, number, name, tree and report with a separate call each. One call can give all of them. No design change.
2. **A note the reader keeps for itself.** After a full lookup, the lookup script saves where it found the job: the effort, the job, and the number of the last event it had read. On the next call it reads only the events written since. Usually that is none or one.
   - **One writer:** the script that reads it. Nobody else knows the file exists.
   - **It can't be stale:** a job's ending is always a later event, so it is always among the ones read.
   - **Losing it costs nothing:** with no note, the script does the full lookup, as today.
   - **The events stay the only record.**
   - It needs the event reader to take "only events after this one". That is a small, general addition in the events' own component, and other readers will want it.
3. **Only if both are not enough:** come back to the owner. Past that point the question is the one already parked for later: how the framework avoids re-reading a growing log. It deserves one answer for every reader, not a special one for this hook.

The stop hook keeps the full lookup, as Dev Beta says.

## 4. One thing the numbers point at

The first pass of the lookup searches **every effort on disk**, finished ones included, on every call. That cost grows with the owner's whole history, not with the job at hand. It will be felt first here, then in the stop hook and in main's turn-end hook, which search the same way. The note in fix 2 hides it for this hook. It should go on the list for the parked discussion about the log, with this measurement beside it.

## 5. The matrix itself

86 of 86 with a red control, in the real layout, is the result I asked for after the hook rework. I haven't read its raw cells this time. I'll read them when the step 4 results come, since the two together are the final bar.
