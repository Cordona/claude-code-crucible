# The agents tree and the fix events: Fable's view (2026-11-24)

By Crucible Fable Reviwer, for the owner, on `agents-tree-proposal.md`. Design only. Talking only; the owner's go is the only go.

**What I read:** the proposal, and the current tree in new-rewrite. I ran nothing.

## Verdict

1. **The proposed tree is right.** It is better than what I suggested: I asked only for a clearer name, and the owner's split puts each agent's rules where a reader looks for them.
2. **Two fix events: yes, and the owner is right against my finding 2.** One condition: split the job kind as well, not only the event.
3. **Nothing is against the constitution.**

## 1. The tree

**Right as proposed.** Shared holds what every agent uses and names no agent; each agent holds its own rules and its own list of what it hands in.

**The `submissions/` folder is what makes "who submits what" plain.** Listing one agent's folder shows every kind it hands in, and each file names its event and its rules.

**Three things to hold to when it is built:**

- **No agent's lib includes another agent's lib.** The tester's test report is close to the build report, so `report-common.jq` will hold most of today's rules, and the builder's `build-report.jq` will be short. That is fine. It states the builder's own choices (its blocker kinds, its unchanged-tree rule), and the tester never reaches into the builder.
- **"One file per kind" has one exception in the proposal:** `test-plan-report.jq` serves the plan and its update. Either say so, or give the update its own small file holding the answers rule.
- **Two files named `fix-report.jq`** in two components will confuse a search. Point 2 below gives them different names.

## 2. Two fix events

**I approved one `fix.submitted` for both sides, and later asked for its rule to be shared. I'd now take both back.** When I approved it, nothing treated the two fixes differently. Now three scripts do, and each uses the agent type as a stand-in to tell them apart:

| What differs | Where today |
|---|---|
| The report's rules, and what may change in the tree | each agent's own rules |
| The fix loop: the build's fixes and the tests' fixes count their rounds apart | `iteration.jq`, by agent type |
| Which fixes belong to "the build under test" | `tester-facts.sh`, by a stand-in |

So they are two kinds of work that share a name. The owner's second comment, that they will differ, is already true.

**The condition: split the job kind, not only the event.**

- The proposal keeps the kind `fix` and gives it two events. Everywhere else a kind has exactly one event, and recovery, the report folder and the commit all go from the kind. One kind with two events would be the only special case.
- With two kinds, `build-fix` and `test-fix`, each has its own event, its own `submissions/` file, its own rules file and its own report folder, with no stand-in left:
  - the fix round counts per kind, which is what "per agent type" was standing in for;
  - `tester-facts.sh` asks for the build's fixes by name.
- Nothing about fixes stays in the shared component except `fix-answers.jq`: the three answers and the sent-back rule, which are the same for both.

**What it costs, so it is said:**
- one more kind and one more event type;
- every reader that asks "is this a fix" takes both. Put that question in one function beside the iteration count, so no reader lists the two names itself;
- `report-schemas.md` and the two agent specs change the name;
- the human's fix choice stays one event. The split is in the work, not in the choice.

**Without the split,** the one shared rule would stay as it is, and the `submissions/` folders alone would show who hands in a fix. That is less than the owner asked for, and it keeps the stand-ins.

## 3. The constitution

**Nothing against it.** The split serves three of its points: small pieces that know little of each other, one home for each rule, and events as plain facts with one meaning each.

**One caution:** "they may differ one day" is not by itself a reason to split, and I wouldn't split on it. The reason here is that they already differ in three places.
