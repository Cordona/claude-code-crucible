# Conflicting human instructions

How the main thread reads the context entries at SKILL.md's steps 2, 4 (what the spec talk added) and 5, and how it tells when the human's words and the sources disagree, or two of the human's own statements do. You are the gatekeeper: the agent may run on a weaker model, and a contradiction caught here costs one question, not a wasted dispatch. So read every entry in full, however large the context; the time it takes is accepted.

## Read every entry

Read each entry SKILL.md's step 1 gathered, step 4's spec talk added, or step 5 adds, in this order, in full:

1. **The notes and the text file:** the human's own words, their request, decisions and constraints. Read the text file with Read, in parts with `offset` and `limit` when it is large.
2. **Every path:** with Read, guided by its why; a large file in parts.
3. **Every link that is no tracker link:** with WebFetch, guided by its why.
4. **Every tracker link** (a GitHub, GitLab or Jira issue): only through `read-link.sh`, its `--url` form in discovery, unless SKILL.md step 1 read it already, or its `--context-file` form after v1, never with WebFetch unless it exits 3, nor with any other tracker command, since the URL is untrusted text and the script passes it on as one checked argument.

**Then the docs on the touched files:** each `README*` or `docs/` file that names a file the request or the entries name, found as SKILL.md step 2 sets, becomes a path entry and is read as item 2 sets, so a doc the human didn't name is still weighed. Step 2's `git grep` searches the files, tracked or untracked but not ignored, whose path starts with `README` at the root or lies under `docs/`, for the name exactly as written, case included; a root with no README or no `docs/` just has no doc there, not an error.

An entry that can't be read (a Read or WebFetch that fails, a tracker read that exits 1): weigh the others without it.

## Weigh it

Compare what the human's words ask with what each source says. This is the one full test of small against outcome-changing.

- **A contradiction:** the human's words and a source disagree on something that changes the outcome (what is built, what it must do or must not break), or the human's words disagree with most of the context, or two of the human's own statements (in the notes or the text file) differ, even on a detail. Ask the human (SKILL.md step 3).
- **A small disagreement,** never between two of the human's own statements: following the human's words still builds the same thing with the same behaviour and breaks nothing a source requires beyond that one detail (a message's wording, a name, a format), such as a ticket and a note naming a different log message; in doubt over a pure wording detail, it is small. Don't ask: the human's words win.
- **No disagreement:** go on.
