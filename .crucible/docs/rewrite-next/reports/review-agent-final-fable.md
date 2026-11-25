# The review agent's spec, final: Fable's check (2026-11-24)

By Crucible Fable Reviwer, for the owner. My judgement only; the owner's go is the only go.

**What I read:** `review-agent.md` draft 2 in full, against `review-agent-fable.md` and the owner's decisions in its section 15. I ran nothing.

## Verdict

**Ready to build, by my judgement.** Everything I advised is applied as written, and the two places where the owner decided against me are sound.

**On the owner's worry:** most rules here have a real failure or a key behind them. **Four don't, or not yet,** and one line contradicts a decision. None of them blocks the build; I'd take them out before it starts, since it is less to build.

## 1. The owner's two decisions against my answers

| Decision | My view |
|---|---|
| No `for: <lens>` on an external finding | **Accept.** No run has failed for lack of it. What to watch in the first real triage: a security point judged by another lens is numbered under that lens and is not in the security count |
| No moved-tip case | **Accept.** If the loop never runs a fix during a review, my case can't happen |

## 2. Rules without a failure behind them

| Rule or stamp | Why it can go | What I'd do |
|---|---|---|
| `noticed[].for` naming the reviewer's own lens is refused | no real case; a handoff to oneself harms nothing | drop it |
| `reopens` must name a settled ID | "settled" is decided by the merge, which is the review loop's spec and isn't built. The rule can't be checked honestly yet | keep the field as text for now; add the rule with the loop |
| A key stamped on each `noticed[].for` entry | its only reader is the answer to a routed notice, also the loop's | stamp it when the loop is built |
| Foreign review: "remove `fixes`" | the unknown-key rule already refuses it, with the kind's own key list | drop the special rule; one refusal, not two |

**One rule to decide with the agent's tools, not here:** the tree check. If the reviewer agent gets no tool that can write, it is a rule for nothing, by the same reasoning the owner used on the tip. If it gets a shell, the rule earns its place. That is the dispatch talk's answer.

## 3. One contradiction

The field table in section 2 still says an `out_of_scope` finding is "never a fix target". Decision 14 says the human can still choose it. The table should say: not a fix target by default, listed as a follow-up, and the human may choose it.

## 4. Rules I checked and would keep

Each of these protects a key a script reads, or a decision the owner already made:

- a thread, a fix or an item named twice, or not in the job;
- the status that must match the fixer's (a decline gets agree or disagree);
- an edge case without its proof, a hypothetical without what makes it real;
- a finding outside the change with no line it relates to;
- a `valid` without a finding, and a reply on a `valid`;
- an internal ID in text a human reads;
- a key only a script fills in.

## 5. For the build

- **Proof case 12** asks for two reviewers stopping "at the same moment". Start the two hooks together and show the two IDs; don't build a harness to force the race.
- **The live run** needs a re-review's job, which carries the earlier findings. The dispatch isn't built, so the proof writes that job itself, as for the builder and the tester.
