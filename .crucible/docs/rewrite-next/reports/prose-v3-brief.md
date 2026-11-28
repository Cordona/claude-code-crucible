# Agent prose v3: agents blind to the plumbing

By Dev Beta, at the owner's request. The drafts are in `prose-v2/`: `code-builder.md`, `code-tester.md`, `code-reviewer.md`, `agent-conduct.md`. They were edited in place; the live copies under `new-rewrite/domains/software-development/core/agents/` still hold v2, as you approved it.

## The owner's rule

"No subagent should know about the plumbing handled automatically by scripts, hooks and eventually main." An agent's prose speaks only of what it receives (the task, the findings, the plan, the lens, the report path, the message saying what is wrong with its report) and what it writes, in plain words.

## What changed from v2

- **No kind names.** The openings give each task in words. The headings are in words:
  - builder: "When you fix findings, also";
  - tester: "Your plan", "When you rework the plan, also", "Your report on written tests", "When you fix findings, also";
  - reviewer: "When you review a change", "When you review someone else's MR", "When you challenge a test plan", "When you judge an outside review of our MR".
- **No mechanism as a reason:**
  - dropped: "When you stop, your report is checked and your tree is committed for you", and the reviewer's "When you stop, your report is checked, and changed files are refused";
  - "only the tree is committed, so a change elsewhere goes unseen" became "a change elsewhere is lost";
  - "A break left in the tree would be committed" became "would ship";
  - "Never write its `id`: one is given to it when you stop" became "A finding has no `id`".
- **"job" became "task".** For example, "the known failures you were given" and "one per finding you were given". "Never write a finding ID, a job or an iteration into the code" became "a finding's ID or the review history".
- **`agent-conduct`:** "When your stop is held" became "When you're told what is wrong with your report".
- **The builder no longer lists `mutation`.** Only the tester breaks code to prove its tests can fail. After approval, the builder's own check drops it too, so the builder can't report it.

Kept on purpose:
- the report path, the field names and values, the plan's IDs, and the lens, because the agent receives or writes them;
- the frontmatter `description`, which still names the kinds. It's for main's dispatch, and the agent never acts on it.

## What Fable is asked

1. Is any plumbing left that the agent doesn't act on?
2. Did removing a reason lose something the agent needs in order to act right? For example, an agent that isn't told why it must not commit, or why a finding has no ID.
3. Does "the task" hold up, given that the dispatch talk still has to decide how a job reaches the agent (in words, or naming the kind)?
