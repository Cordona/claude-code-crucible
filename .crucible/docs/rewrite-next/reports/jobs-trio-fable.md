# The test-plan trio on the new chain: Fable's review (2026-11-27)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** the six kind files in `jobs/define/kinds/`, `jobs_view` in `jobs/track/scripts/lib/jobs.jq`, the challenge branch of `job-of.sh`, the `one_of` check in `job-resolve.jq`.

**Not done:** nothing was run; the evidence counts are Dev Beta's. I did not read the tester's or reviewer's facts scripts, or the card.

## Verdict

**The trio is right as shapes: refs only, the human's words as an event, the plan named by main.** Nothing here should stop its live run.

**On complexity, this is the step where two things start to grow,** and both are cheaper to settle now, with three kinds moved, than after the fix-loop kinds add theirs.

## 1. The job lookup is starting to know kinds

**`job-of.sh` now has a branch for one kind's payload:** if the job names a challenge, open that challenge's pinned report and lift its `challenges` into the view. And `jobs_view` names `plan`, `challenge` and `words` one by one, with `words` turned from a ref into a gate's answer.

**Each is small and correct. The direction is the problem.** The kinds still to move each carry a payload of the same sort: the chosen findings for the two fixes, the earlier findings for a re-review, the threads for an outside review. If each lands as another branch in the lookup, `jobs/track` becomes the place that knows every kind's inputs, and the kind files stop being where a kind's facts are.

**The simpler line, before the next kind moves:**
- the view passes a job's refs through as they are, by name, without knowing any of them;
- `jobs/track` offers one general act: the pinned report of an event;
- the agent's own facts script, which already reads the view, turns its refs into what it needs. The tester knows it wants a challenge's challenges; the lookup doesn't have to.

That changes each agent's facts script once, which "the agent side unchanged" has avoided so far. It is the right moment to stop avoiding it: the adapter was a seam for the move, not a place for kind logic to settle.

**Not a blocker for the trio.** A decision before the fix-loop kinds.

## 2. The kind file is becoming a small language

After six kinds a kind file can say: `agent`, `part`, `tree`, `write_scope`, `range`, `known_failures`, `one_of`, `one_standard`, and per ref `event`, `required`, `list`, `named`. Four of those arrived with one kind each.

**Still fine: each is a plain fact, and resolve reads them without naming a kind.** The thing to hold: a new word enters the kind file only for a fact resolve must check. If the next kinds each bring a word, the file is a kind's name spelled as flags. I'd look again after the fix kinds.

## 3. The shapes

- **`words` as a ref to a `gate.answered`: right,** and it keeps the owner's rule that the human's words are an event. One gap: any gate passes, including one whose answer is "Approve". The guard that fits is the card: the rework's job card should show the words, and the challenge's ids, because they are what the human decides on. That was the open point from the first stress run, and this kind is where it bites first.
- **`one_of` (a rework needs a challenge or words): right,** and checked at resolve where it can't go stale.
- **`named` for the plan: right.** It replaces "the latest" as I asked; main names the plan and resolve checks its type.
- **Write scopes out of the three submissions files: right,** and each kind has the word in one place.

## 4. The frozen fixture

**It should shrink with each kind that moves.** "Shrinking" meant this: once the trio runs on the new chain (120 cases), the old-chain regression cases for these three kinds are duplicates. Move or delete them, so that what still writes `job.dispatched` is only the kinds not moved. Otherwise the fixture stays the same size until the last day.

## 5. For the live run

- The rework from words: the card shows the words the human approved against.
- A rework naming neither a challenge nor words is refused at resolve with the line that says what to name.
- The tester's and the reviewer's skills byte-equal, as in the last run.

## 6. For the owner

One decision, not urgent: **where a kind's inputs are turned into what the agent reads.** In the job lookup, one branch per kind (as built for the challenge), or passed through and read by the agent's own script (my lean, section 1).
