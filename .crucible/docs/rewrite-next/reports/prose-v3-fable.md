# Agent prose v3, agents blind to the plumbing: Fable's check (2026-11-25)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** the brief and the four drafts in `prose-v2/`, against the v2 text I reviewed this morning. I checked three points against the built checks: which reports accept `noticed`, the builder's gate names, and what a refused stop can say.

**Not done:** I ran nothing.

## Verdict

**The rule is applied cleanly, and I'd apply the drafts after four wording edits.** No kind name, no hook, no commit and no event is left in the text an agent reads. Three of the removed reasons took something with them, and one new reason is untrue.

| # | Line | Problem |
|---|---|---|
| 1 | builder 21, tester 25 | "a change elsewhere is lost" is untrue |
| 2 | builder 22, tester 26 | "Never commit" has no reason left |
| 3 | reviewer 29 | "A finding has no `id`" contradicts what the reviewer sees |
| 4 | `agent-conduct` 13 | "what is wrong with your report" is too narrow |

## 1. Is any plumbing left?

**No.** What remains is what the agent receives or writes: the report path, the field names and values, the IDs it is given, the lens, the known failures.

- **The frontmatter `description`** still names the kinds. I agree with keeping it: main reads it, and the agent doesn't act on it.
- **Reviewer, line 29:** "Used in reviews, foreign reviews and valid external points" still uses the kinds' words. Use the headings' words: a review of a change, of someone else's MR, and a valid point of an outside review.
- **The builder without `mutation`:** right. Only the tester breaks code to prove a test. The builder's check still accepts the name today, so the order of the two changes doesn't matter.
- **`noticed` in the plan, the challenge and the outside review:** the checks accept it now, so the gap from my last two reviews is closed.

## 2. Did removing a reason lose something?

1. **"A change elsewhere is lost."** It isn't lost. A file changed outside the tree stays changed on the machine, and nobody reviews it. "Lost" tells the agent the change is harmless. Write: "Change nothing outside your tree: only the tree is your work, and nobody reviews a change made elsewhere."
2. **"Never commit, and run no git command that writes."** It now stands with no reason, and the constitution asks each rule to name the failure it prevents. The reason needs no plumbing: "your tree is handed in as you leave it." The agent acts on that. It is also what makes the tester's "a break left in the tree would ship" make sense.
3. **"A finding has no `id`."** On a re-review the same agent is handed findings with IDs and writes them in `fixes` and `reopens`. Stated as a fact, the line is false to what it sees. State it as the rule: "Never give a finding an `id`."
4. **`agent-conduct`, line 13.** A refusal isn't always about the report. The reviewer can be told "you changed files: undo your changes", and the tester that it changed a file outside the plan. Write: "When your work comes back with what is wrong, one line each, change exactly that, then finish again."

**Removed and not missed:**
- "your report is checked and your tree is committed for you";
- the reviewer's "changed files are refused". "A reviewer that edits the code is reviewing its own work" is the reason, and it stayed.

## 3. Does "the task" hold?

**Yes.** Each definition branches on something the agent can see in its prompt: findings to fix, a plan to write, challenges to answer, fixes to judge. It doesn't need the kind's name to pick its section.

**One condition for the dispatch talk.** The tester writes two different shapes to the same report path, a plan or a report, and picks by its task. So the prompt must state the task in the same words as the definition's opening and headings. Those words belong to the agent, not to the dispatch: I'd keep the one sentence per kind in the agent's own folder, and have the dispatch only place it. Otherwise the dispatch ends up holding each agent's vocabulary, which is the coupling the owner ruled out.

## 4. One line that is new since v2

**Reviewer, line 19:** "In a review of a build, a missing test is never a finding: the tests are written after the review." It speaks of the order of work, which is close to flow. I'd keep it: it is the reason, and the agent needs it to act right.
