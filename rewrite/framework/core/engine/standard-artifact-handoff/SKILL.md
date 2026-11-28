---
name: standard-artifact-handoff
description: How the main thread and agents hand work over as artifacts (drafts, plans, reports, reviews, briefs, specs) written once to a file and passed by full absolute path, with the text shown only on the human's confirmed ask. Bind when producing a document for someone else, handing one over, or being asked for its text; every agent preloads it. Writes only the owed record `show.sh` writes for its line. Not for pushback on the human's habits (`procedure-context-efficiency`).
user-invocable: false
---

# Standard: Artifact handoff

## Scope

- **An artifact** is a document the main thread or an agent produces for someone else to read or use: a draft (an issue, PR or MR body, a commit message), a plan, a report, a review, a brief, a spec, research, a summary.
- **Not artifacts,** so these rules don't apply to them:
  - a card a script prints for the human (a gate, metrics, what-next, a report summary, a line): `human-view` shows it; and a script's stderr;
  - an input the work starts from: the human's words, a ticket, a context entry;
  - installed skill, plugin and rules text, and the context JSON: an agent's first message carries them inline;
  - an eval run's prompt and its answer;
  - an excerpt of at most one line, quoted with its absolute path and line (an instruction-shaped line, a contradiction's two sides, a validator error);
  - short content: a few lines for one reader, not reused or passed on, may go inline. Anything document-like is an artifact and goes in a file.

## Never

- **Never hand over an artifact's text,** in a reply, a brief, a message or the chat: hand over its path. The one exception is the human's confirmed ask (Always).
- **Never give an artifact's path relative, with `~`, shortened or cut.**
- **Never regenerate or re-render an artifact for display.** A copy a script makes to keep a record intact (a gate record, a context version, a snapshot) is no second artifact.
- **An agent never asks for an artifact's text,** only its full absolute path.
- **A shipped skill or agent never cites a throwaway run file.**

## Always

- **Write each artifact once, to a file;** a report a hook sends back is fixed in place until it passes, then never changed. Inside an effort, every Markdown artifact the main thread writes goes in the effort's `drafts/` folder, allocated with `crucible.sh new --kind drafts` as `crucible` sets, spec drafts included; a context doc goes where `crucible` sets. Outside an effort, an artifact goes in a file in the session scratchpad.
- **Match an artifact's length to what the task needs:** cover the substance, with no filler sections, redundant summaries or boilerplate. Where a schema or a script-checked format fixes the shape, that shape holds.
- **Hand it over by its full absolute path.** A path to a repository file inside a stored artifact may stay repo-relative when every template that prints it joins it to the repository root and prints it whole.
- **A subagent's report is a file, never its reply's text:** it reaches the main thread as its agent file and flow set (a path in its reply, or a file a hook checks).
- **A brief passes every artifact it needs by its full absolute path.**
- **An artifact that cites another durable artifact cites it by its full absolute path.**
- **When the human asks to see an artifact's text,** however the ask is worded (`show me the commit text`, `can I see the report?`): first show the line `show_text_offer`, with `--arg path '<path>'`, `<path>` being the artifact's full absolute path; `<views>` is `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/standard-artifact-handoff/views"`. Show the text only after a yes. (Main thread only; an agent never shows a line, it hands over the path.)

## Dependencies

- **`human-view`, not loaded:** its `show.sh` shows this skill's line from `views/lines.jq` (Always).
- **Tools:** Bash, for that line, on the main thread only.
