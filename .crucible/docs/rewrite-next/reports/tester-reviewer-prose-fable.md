# The tester's and reviewer's prose: Fable's check (2026-11-24)

By Crucible Fable Reviwer, for the owner. Talking only; the owner's go is the only go.

**What I read:** `code-tester.md` (69 lines), `code-reviewer.md` (58 lines) and the builder's current file, against `test-agent.md`, `review-agent.md`, the workers' real cases and the constitution.

**Not done:** I didn't check the key and value names against the built rules. Dev Beta did, and I took that as given.

## Verdict

**Both are lean and stand alone, and the builder's lessons are in.** About half of each file is the report's shape, which is right while a job ends at the second refused report.

**Seven lines are missing, three in the tester and four in the reviewer.** Each is a slip that no script catches and that the workers met in real work. One question about the reviewer's tools is the owner's.

## 1. The tester

| # | The slip | Why nothing catches it | The line |
|---|---|---|---|
| 1 | A plan update that holds only what changed | the rules check a plan's shape, not that nothing was dropped. A rework that leaves out three tests passes, and they are gone | "A rework is the whole plan again, with the changes applied." |
| 2 | A test loosened until it passes | the plan's `keeps` is checked when the plan is made. Nothing checks it when the test is written. It was the workers' most valued field | on the test job: a test you change still asserts what the plan says it keeps; loosening it to pass hides the bug |
| 3 | A captured fixture that holds a real token or a customer's data | the report-text rule covers the report. A fixture is committed with the tree | "A captured fixture holds no real secret or customer data: mask it before you save it." |

**Smaller:**
- **"a `production_bug` blocker at the wrong production line"** reads as if the line were mistaken. Say: at the production line that is wrong.
- **The builder's line on `narrowed`** (a run on part of the checks is `narrowed`) is missing here. The tester's file says only that `narrowed` needs a note.

## 2. The reviewer

| # | The slip | Why nothing catches it | The line |
|---|---|---|---|
| 1 | A finding invented to have something to report | nothing can check it. The file never says that an empty review is a good one | "Nothing wrong is a result: write `{}`. Never add a finding to have one." |
| 2 | An outside reviewer's line number used as it is | three workers: the bot comments on the commit it saw, and the lines have moved. The location check passes on the wrong line | for an external review: their line numbers are from the commit they reviewed; find the line as it is now |
| 3 | A foreign review written in our own voice | its claims and suggestions are posted to a colleague as comments. The file says so only for a note | for a foreign review: write the claim and the suggestion for the MR's author; they become the comments |
| 4 | A reply written as a note to ourselves | a reply is posted to the outside reviewer | on `reply`: the text to post, as you would say it to them |

**Optional, and I'd wait for a real run:** a fix that breaks something else is a new finding, not `open` on the old one. Three workers mention it, and a misfiled finding is not a lost one.

**The owner's call: the reviewer has a shell.** Its tools include Bash. The old reviewers had none, and "a reviewer changes nothing" was true by construction.
- With a shell, two things guard it: one line of prose, and the tree check, which sees the tree and nothing outside it.
- If the shell is only for reading a diff, the dispatch could hand the diff over. If a lens needs to run something, the shell stays and the check earns its place.
- I'd settle it with the dispatch, since it decides what a reviewer is given.

## 3. The constitution

- **Section 6, thin prose:** both hold. The rules that aren't self-evident give their reason (why a unit test needs one, why a break goes in a copy, why a reviewer doesn't edit).
- **Section 15, stands alone:** both hold. Neither names another file, and "your prompt gives you the job" no longer describes the dispatch.
- **One thing to know:** the same two paragraphs on untrusted content and secrets, the customer-data line and the held-stop line are now in all three files. That follows the owner's rule that each agent owns everything of its own. If a fourth copy comes, the dispatch could add them to every agent's prompt; that is a question for the dispatch talk, not a change now.

## 4. The owner's plan: no live runs now

**Fine for these two.** Their rules were proven with stand-in agents, and the prose can't be judged fairly until the plugins and the dispatch give an agent its real prompt.

**What to count first when that day comes:** how often a report is accepted at the first stop. It is the measure of whether the shapes in these files are enough, and it is cheap to read from the events.
