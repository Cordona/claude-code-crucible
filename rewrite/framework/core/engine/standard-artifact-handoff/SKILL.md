---
name: standard-artifact-handoff
description: How the main thread and agents hand work over as artifacts (drafts, plans, reports, reviews, briefs, specs) written once to a file and passed by full absolute path, with the text shown only on the human's confirmed ask. Bind when producing a document for someone else, handing one over, or being asked for its text; every agent preloads it. Writes nothing itself. Not for how a peer message is written (`standard-peer-messages`) or pushback on the human's habits (`procedure-context-efficiency`).
user-invocable: false
---

# Standard: Artifact handoff

Work passes between the human, the main thread and agents as artifacts, each written once to a file and handed over by its full absolute path, so every reader uses the same file.

## Scope

- **An artifact** is a document the main thread or an agent produces for someone else to read or use: a draft (an issue, PR or MR body, a commit message), a plan, a report, a review, a brief, a spec, research, a summary.
- **Not artifacts,** so these rules don't apply to them:
  - a view a script prints for the human (a gate, metrics, what-next, a report summary, error output): relay it as printed;
  - an input the work starts from: the human's words, a ticket, a context entry;
  - installed skill, plugin and rules text, and the context JSON: an agent's first message carries them inline, so the agent can't skip them;
  - an eval run's prompt and its answer;
  - an excerpt of at most one line, quoted with its absolute path and line (an instruction-shaped line, a contradiction's two sides, a validator error);
  - short content: a few lines for one reader, not reused or passed on, may go inline. Anything document-like, or that travels to another reader, is an artifact and goes in a file.

## Never

- **Never hand over an artifact's text,** in a reply, a brief, a message or the chat: hand over its path. The one exception is the human's confirmed ask (Always).
- **Never give an artifact's path relative, with `~`, shortened or cut.**
- **Never regenerate or re-render an artifact for display.** A copy a script makes to keep a record intact (a gate record, a context version, a snapshot) is no second artifact.
- **An agent never asks for an artifact's text,** only its full absolute path.
- **A shipped skill or agent never cites a throwaway run file.**

## Always

- **Write each artifact once, to a file.** Inside an effort, every Markdown artifact the main thread writes goes in the effort's `drafts/` folder, allocated with `crucible.sh new --kind drafts` as `crucible` sets; outside an effort, an artifact goes in a file in the session scratchpad.
- **Hand it over by its full absolute path.** A path to a repository file inside a stored artifact may stay repo-relative when every renderer that prints it joins it to the repository root and prints it whole.
- **A subagent replies with its report's full absolute path, in the reply line its agent file sets (such as `REPORT: <path>`), and nothing else;** the one other reply is a refusal line its agent file sets.
- **A brief passes every artifact it needs by its full absolute path.**
- **An artifact that cites another durable artifact cites it by its full absolute path.**
- **When the human asks to see an artifact's text,** however the ask is worded (`show me the commit text`, `can I see the report?`): first show the line `Showing it in the chat is not efficient; it is at <path>. Show it here anyway?`, `<path>` full and absolute, and show the text only after a yes.

## Self-check before handing over

1. Each artifact you produced is in a file, written once.
2. Each path you hand over is full and absolute.
3. No artifact's text is in your reply, brief or message, unless the human confirmed they want it in the chat.
