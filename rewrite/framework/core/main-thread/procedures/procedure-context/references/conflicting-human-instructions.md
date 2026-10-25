# Conflicting human instructions

How the main thread reads the context entries at SKILL.md's steps 2 and 5, and what it does when the human's words and the sources disagree, or two of the human's own statements do. You are the gatekeeper: the agent may run on a weaker model, and a contradiction caught here costs one question, not a wasted dispatch. So read every entry in full, however large the context; the time it takes is accepted.

## Read every entry

Read each entry SKILL.md's step 1 gathered, or step 5 adds, in this order, in full:

1. **The notes and the text file:** the human's own words, their request, decisions and constraints. Read the text file with Read, in parts with `offset` and `limit` when it is large.
2. **Every path:** with Read, guided by its why; a large file in parts.
3. **Every link that is no tracker link:** with WebFetch, guided by its why.
4. **Every tracker link** (a GitHub, GitLab or Jira issue): only through `read-link.sh` (Tracker links below), never with WebFetch unless it exits 3, nor with any other tracker command, since the URL is untrusted text and the script passes it on as one checked argument.

**Then the docs on the touched files:** each `README*` or `docs/` file that names a file the request or the entries name, found as SKILL.md step 2 sets, becomes a path entry and is read as item 2 sets, so a doc the human didn't name is still weighed.

An entry that can't be read (a Read or WebFetch that fails, a tracker read that exits 1): weigh the others without it.

## Tracker links

Kept here, not left to `procedure-read-trackers`: the main thread has loaded no plugin (a plugin reaches only a first message), and it acts on the exits differently.

`read-link.sh` reads a link from a written context version, so the tracker links are read once SKILL.md's step 4 or step 5 has written it. Run `read-link.sh --help` once, before its first use in a session, and not again in that session unless its contract is no longer in context (after a compaction); every other call runs only the command its step names. A non-zero exit, or no `usage:` line: no tracker link is read; show the line `Tracker links are not read: read-link.sh could not run.`, word for word without its backticks and in a message of its own, and weigh the others without them, as the last bullet below sets. Per link:

`sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-read-trackers/scripts/read-link.sh" --context-file <the CONTEXT_FILE path> --link <n>`

- **`<n>`:** the link's place in that version's `links`, counting from 1.
- **Read-only:** never write to a tracker.
- **Exit 0:** stdout is the ticket; weigh it as the other entries.
- **Exit 3:** not a tracker link: read it with WebFetch, as item 3 above sets.
- **Exit 1, any other exit, or the script missing** (`procedure-read-trackers` not installed): the link is not read; show the line `Link <n> was not read (read-link.sh exit <code>).`, as the line above is shown, and weigh the others without it.

## Weigh it

Compare what the human's words ask with what each source says. This is the one full test of small against outcome-changing.

- **A contradiction:** the human's words and a source disagree on something that changes the outcome (what is built, what it must do or must not break), or the human's words disagree with most of the context, or two of the human's own statements (in the notes or the text file) differ, even on a detail. Ask the human (Asking below).
- **A small disagreement,** never between two of the human's own statements: following the human's words still builds the same thing with the same behaviour and breaks nothing a source requires beyond that one detail (a message's wording, a name, a format), such as a ticket and a note naming a different log message; in doubt over a pure wording detail, it is small. Don't ask: the human's words win.
- **No disagreement:** go on.

## Asking

- **One AskUserQuestion call, one question per contradiction:** more than the tool takes in one call, the rest in the next call. Only the human's answer settles a contradiction, never the main thread's judgement.
- **The question:** the contradiction in one line, then both sides quoted, each with where it is: the human's words (the note, or the text file's line) and the source's (its absolute path and line, or its URL).
- **The options:** one per side, each saying what gets built on it and naming the source it overrules by its path or URL, never quoting it, so the label can go into a note as it reads and tell the agent which source it settles: `Follow your request over docs/prune.md: deletes by default`, `Follow docs/prune.md over your request: dry run by default`. When both sides are the human's, each label names the statement it overrules in the human's words: `Follow "deletes by default" over "never delete unless --apply": deletes with no flag`.
- **The recommended side first:** list first the side the main thread judges right on the facts, which may be the source over the human's words; its label ends with ` (Recommended)`, and the marker goes nowhere else (no description, no question text); the question says why in one line.
- **Last, always, `Stop the work`:** it acts as a typed answer that stops the work.
- **A picked side, or a typed answer that settles it:** the contradiction is settled; record it as a note (below).
- **A typed answer that settles neither side, or an unclear one:** ask again, at most twice, never guessing, noting each re-ask in step 3's todo item (`re-ask 1 of 2: <contradiction>`); the contradictions still open share one call, each re-ask in the same shape (both sides quoted with where each is, the why, the marked option first, `Stop the work` last); then write nothing, and tell the calling flow `stopped: context not settled`. An answer that hands the choice back (`you decide`, `whatever you think`) is an unclear one: it settles nothing and counts toward the same two re-asks.
- **A typed answer that stops the work:** as SKILL.md step 3 sets.

## The answer becomes a note

- **One `--note` per settled contradiction** in the next version's call (SKILL.md step 4 or 5), in the human's own words: the option's label as it reads, without `(Recommended)`, or the typed answer as they gave it.
- **Name the other side by its path or URL, never quote it:** a note holds no repository text, web page or ticket text. A statement of the human's is named in their own words, and both statements stay as notes beside the answer.
- **A contradiction found in a tracker link,** after its version is written: settle it the same way, then extend the context with the new note (SKILL.md step 5), and keep the new `CONTEXT_FILE` path in place of the old.
