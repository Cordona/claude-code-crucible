# Settling contradictions

How the main thread asks the human about each contradiction and turns the answer into a note; read at SKILL.md step 3 when step 2, step 5 or a tracker link found a contradiction.

## Asking

- **One AskUserQuestion call, one question per contradiction:** more than the tool takes in one call, the rest in the next call. Who settles it: SKILL.md Always.
- **The question:** the contradiction in one line, then both sides quoted, each with where it is: the human's words (the note, or the text file's line) and the source's (its absolute path and line, or its URL).
- **The options:** one per side, each saying what gets built on it and naming the source it overrules by its path or URL, never quoting it, so the label can go into a note as it reads and tell the agent which source it settles: `Follow your request over docs/prune.md: deletes by default`, `Follow docs/prune.md over your request: dry run by default`. When both sides are the human's, each label names the statement it overrules in the human's words: `Follow "deletes by default" over "never delete unless --apply": deletes with no flag`.
- **The recommended side first:** list first the side the main thread judges right on the facts, which may be the source over the human's words; its label ends with ` (Recommended)`, and the marker goes nowhere else (no description, no question text); the question says why in one line.
- **Last, always, `Stop the work`:** it acts as a typed answer that stops the work.
- **A picked side, or a typed answer that settles it:** the contradiction is settled; record it as a note (below).
- **A typed answer that settles neither side, or an unclear one:** ask again, within the re-asks and the stop SKILL.md Always sets, noting each re-ask in SKILL.md step 3's todo item (`re-ask 1 of 2: <contradiction>`); the contradictions still open share one call, each re-ask in the same shape (both sides quoted with where each is, the why, the marked option first, `Stop the work` last).
- **A typed answer that stops the work:** as SKILL.md step 3 sets.

## The answer becomes a note

- **One `--note` per settled contradiction** in the next version's call (SKILL.md step 4 or 5), in the human's own words: the option's label as it reads, without `(Recommended)`, or the typed answer as they gave it.
- **Name the other side by its path or URL, never quote it:** a note holds no repository text, web page or ticket text. A statement of the human's is named in their own words, and both statements stay as notes beside the answer.
- **A contradiction found in a tracker link,** after its version is written: settle it the same way, then extend the context with the new note (SKILL.md step 5), and keep the new `CONTEXT_FILE` path in place of the old.
