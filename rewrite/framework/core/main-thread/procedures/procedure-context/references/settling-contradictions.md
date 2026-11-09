# Settling contradictions

How the main thread asks the human about each contradiction and puts the answer into the spec draft.

## Asking

- **The question:** the contradiction in one line, then both sides quoted, each with where it is: the human's words (as they said them) and the source's (its absolute path and line, or its URL).
- **The options:** one per side. Each says what gets built on it and names the source it overrules by its path or URL, never quoting it: `Follow your request over docs/prune.md: deletes by default`, `Follow docs/prune.md over your request: dry run by default`. When both sides are the human's, each label names the statement it overrules in the human's words: `Follow "deletes by default" over "never delete unless --apply": deletes with no flag`.
- **The recommended side first:** list first the side the main thread judges right on the facts; it may be the source over the human's words. Its label ends with ` (Recommended)`, and the marker goes nowhere else (no description, no question text). The question says why in one line.
- **Last, always, `Stop the work`:** it acts as a typed answer that stops the work.
- **A picked side, or a typed answer that settles it:** the contradiction is settled; put it into the spec draft (below).
- **A typed answer that settles neither side, or an unclear one:** ask again, within the re-asks and the stop SKILL.md Always sets. The contradictions still open share one call, and each re-ask keeps the same shape (both sides quoted with where each is, the why, the marked option first, `Stop the work` last).
- **A typed answer that stops the work:** as SKILL.md step 3 sets.

## The answer goes into the spec draft

- **Each settled contradiction is written into the section of the spec draft it settles,** in the human's own words: the option's label as it reads, without `(Recommended)`, or the typed answer as they gave it. Before the first draft, keep it for that draft.
- **Name the other side by its path or URL, never quote it:** a spec holds no repository text, web page or ticket text.
- **A contradiction found once the spec is approved,** in a tracker link or a new entry: settle it the same way, then revise the spec through SKILL.md's The spec (`references/settle-spec.md` step 2's revision offer).
