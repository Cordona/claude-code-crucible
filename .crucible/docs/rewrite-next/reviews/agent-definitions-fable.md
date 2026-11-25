# Agent definitions: Fable's answer (2026-11-23)

By Crucible Fable Reviwer, for the owner, on `agent-definitions-analysis.md`, `building-blocks-inventory.md` and `agent-definitions-position.md`. Talking only; nothing here is a go or a design.

I read the three files, the constitution, and the old agents' Never and scope sections. I did not open Anthropic's pages; I took the analyst's quotes as given.

## In short

- **The analysis is good, and I agree with most of it.** What it keeps is the judgement; what it cuts is seat machinery.
- **On the dispute, Dev Beta is right about the pairing and wrong about the choice it offers.** "Keep the line until its hook exists" is not a real option, because the definitions and their hooks are the same effort.
- **Of the four answers I agree with two, and correct two.**
- **Three things nobody raised:** the shared piece is two pieces by the owner's own test; some "missing" rules are things an agent can't act on; and the name clash goes away if plugins stop being installed as skills.

## 1. The dispute: must each deletion be paired with its enforcer?

**Yes to a list. No to "the line stays until the hook exists".**

- These definitions can't run in new-rewrite before agent-run exists: there is no dispatch, no job message, no report check, no stop check. So there is no period in which a rewritten body runs without its hooks. The gap Dev Beta fears is a gap in the record, not in time.
- That makes the list the useful thing, and it is more than bookkeeping: **it is the requirements list for agent-run's hooks.** Every rule the analysis hands to "a hook" is a thing agent-run must build or decide not to.
- So the order is: agent-run design first, definitions after, as one effort. Rewriting the bodies now would fix nouns ("job", "sealed", "refusal") that the owner's talk has not settled.

**The list needs three outcomes, not two.** The analysis treats "a hook holds it" as one class. It is three:

1. **Code holds it, and the prose keeps one line with its why.** Example: the write scope. An agent that doesn't know its scope learns it by being refused, call after call. One line is cheaper than three refusals.
2. **No code can hold it, so the prose is the only holder.** These lines are not deletable on "a hook enforces it" grounds, whatever is built:
   - "never edit files through Bash": the write-scope hook sees only Write and Edit;
   - "never touch git's state": a stop check can see it afterwards, it can't prevent it;
   - "never fetch or install anything";
   - "never round up or soften".
3. **Neither: the rule is dropped.** Some lines deserve no hook and no prose (weight follows stakes). The analysis should say so for each, instead of assuming a hook. Example: "never write another report file".

One check on the analysis under this: it says the HIGH grade for "a test file a build diff changes" goes because "a hook already refuses the writes". In new-rewrite nothing does yet. That line is the clearest case for the list.

## 2. The four answers

### 2.1 Does the reviewer keep Bash? No. Agreed, with two corrections

- **Dropping Bash does not make read-only structural.** The reviewer still holds Write and Edit for its report. The old body says so itself: "no tool blocks any other write … so you keep this yourself". Read-only is structural only when a rule also limits those two tools to the report path. That goes on the list from section 1.
- **Without Bash the reviewer can't check that the tree is at its job's commit.** So the analysis's M11 ("if the tree's tip is not your job's commit, review nothing") can't be the reviewer's rule. It is the script's alone: checked when the job starts and when the report is accepted. The same goes for the shared piece's version of it (M8): a builder could check, a reviewer can't, so it is not shared conduct.

`git blame` as a want, not a need: agreed. Wait for a review that suffered.

### 2.2 Preloaded or injected? Preloaded. Agreed

- It is the same for every job, and a preload is loaded by the harness, not by a pointer in the text. So the body depends on a mechanism, not on another document. That is within §15, on two conditions: the body never says "as the conduct sets", and a dispatch check refuses when the preload isn't installed (the old hook did this).
- One more reason: a hot agent gets a preload once. Injected conduct would be sent again with every job.

### 2.3 Merge resolution and the mutation copy stay agent work. Agreed, with two things to settle in the talk

- **A merge job starts on a tree that is not clean and not at a commit.** It has a merge in progress. Every "the tree is at the job's commit, nothing staged" check must know that kind, and the commit that ends it is the catch-up's sync commit, not an ordinary job commit. It is a small thing, but it is the first job kind that breaks the simple rule.
- **"The mutation script moves under the tester's `scripts/main/`" is not decided by saying it.** That folder means "main calls it". A script an agent calls is a third kind of caller, and what an agent may read or run is already an open question in the agent-run map. Leave it there.

### 2.4 Drop the CRITICAL/HIGH cut on flags? Drop the label; keep the bar

Dev Beta's reason goes too far. "The reviewer reports every realistic finding and the display decides" is right for findings in the change, and the old reviewer already works that way. Flags are different: they are things outside the change.

- The old scope text already holds the bar in words: something "you'd stop a colleague in the corridor to mention". That is a scope rule, not a severity filter, and it has its reason.
- So "(CRITICAL or HIGH only)" in the sort step is a second statement of the same bar, as a label. Drop that.
- Don't replace it with "report everything, the display filters". That turns reading for understanding into a second review of code nobody asked about, which the scope rule and "no edge-case hunting" both forbid.

## 3. The name, and one shared piece or two

**Preloading is consistent with §15** (2.2). **The name can wait:** "job" is the direction, not yet the design, and the piece should be named when agent-run names its unit. If it is named now, `code-job-agent` reads like an agent; it is conduct, and the name should say that.

**The larger point: by the owner's split test, this is two pieces.** The analysis lists what the shared piece holds. Sorted by who it is true for:

- **True for every job:** untrusted content, secrets, quote safely, absolute paths, the evidence rules, read in parts, the stop line, the refusal line, the report stands alone, hot or cold.
- **True only for a job that changes a tree:** the write scope, git state, "work already in the tree ships", never edit through Bash, never fetch or install, a change outside the task is recorded, no process traces in code comments, the scope paragraph that sends a better approach to an `open` item.

One piece for all three agents would carry the second group with "if you write code" in front of each line. That is a prose hub.

**What I'd do:** the first group is the conduct every job agent preloads. The second group joins the shared job report, which only the builder and tester preload. That is one cohesive piece: what a job that changes a tree does, from the first edit to the report that commits it. The count of pieces stays what the analysis proposed.

The test either way: no sentence in a shared piece starts with "if you are a …".

## 4. What both missed

1. **Some "missing" rules are ones an agent can't act on.** The analysis adds thirteen. Four are code's alone:
   - never review your own commit;
   - never test your own build;
   - the tree moved, for the reviewer (2.1);
   - a finding closes only through an accepted report.

   A fresh agent can't know which commit it produced, so "a commit you produced is not yours to review: refuse" is a line it can't follow. Prose gets a line only where the agent can do something about it. Otherwise the cut bodies grow back.

2. **The name clash has a cheaper answer than a prefix.** Plugins are injected by a script; nothing loads them as skills. They sit in the skills folder only because the old lister scanned it, which is also why each needs `disable-model-invocation` and `user-invocable: false`. If the dispatch script reads them from the component's own folder, there is no clash, no rename and no frontmatter workaround. That is a dispatch question; raise it there before choosing a prefix.

3. **Three agent definitions is the right number, and the reason should be written down.** With "the job is the credential", someone will ask why not one agent. The answer is the tools: they are frontmatter, and they differ. That is the only structural hold the framework has on a reviewer, so it is the reason to keep three.

4. **The agents never see core's `CLAUDE.md`** (`omitClaudeMd: true`). The analyst caught one rule that must travel with them (hand-over by path). Check the rest of that file the same way once: "the human", and anything else main is told that an agent also needs.

5. **Jira.** The tracker-reading plugin doesn't move, and `trackers` covers GitHub and GitLab only. An effort with a Jira link has no reader in new-rewrite. Not for now; it should be on the owner's list.

6. **How the prose gets written.** This analysis is the "understand" step. The owner's rule for prose is: an approved explanation first, then the harness agents write it. So the next step is the owner's read of this, not an edit.

## What I would do, ranked

1. Nothing to the definitions yet. Take the analysis into the agent-run talk as input.
2. Turn the "a hook holds it" deletions into one list with three outcomes: code plus one line, prose only, dropped. It becomes agent-run's requirements for hooks and checks.
3. In that talk, settle: the write limit on the reviewer's Write and Edit; the merge job's starting state; who an agent's scripts belong to; where plugins live.
4. Then write the pieces, split as in section 3.

## A caution on confidence

All of this rests on the job model, which is the owner's direction and not yet a design, and on agents nobody has run in new-rewrite. The judgement the analysis keeps is proven by the old live runs. Everything it adds is a prediction.
