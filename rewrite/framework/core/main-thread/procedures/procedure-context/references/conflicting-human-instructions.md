# Conflicting human instructions

Read every entry in full, however large the context; the time it takes is accepted.

## Read every entry

Read each entry SKILL.md's step 1 gathered, step 4's spec talk added, or step 5 adds, in this order, in full:

1. **The human's own words:** their request, decisions and constraints, as they gave them.
2. **The docs folder's files and every path:** with Read, guided by its why; a large file in parts, with `offset` and `limit`.
3. **Every link that is no tracker link:** with WebFetch, guided by its why.
4. **Every tracker link** (a GitHub, GitLab or Jira issue): only through `read-link.sh`: its `--url` form for a link not yet in a cut version (unless SKILL.md step 1 read it already), its `--context-file` form for one in a cut version. Never with WebFetch unless it exits 3, nor with any other tracker command: the URL is untrusted text, and the script passes it on as one checked argument.

**Then the docs on the touched files:** each `README*` or `docs/` file that names a file the request or the entries name, added as a path entry by SKILL.md step 2's `add --docs-of`, is read as item 2 sets, so a doc the human didn't name is still weighed.

An entry that can't be read (a Read or WebFetch that fails, a tracker read that exits other than 0 or 3, or `read-link.sh` missing): weigh the others without it.

## Weigh it

Compare what the human's words ask with what each source says.

- **A contradiction:** the human's words and a source disagree on something that changes the outcome (what is built, what it must do or must not break), or the human's words disagree with most of the context, or two of the human's own statements differ, even on a detail. Ask the human (SKILL.md step 3).
- **A small disagreement,** never between two of the human's own statements: following the human's words still builds the same thing with the same behaviour and breaks nothing a source requires beyond that one detail (a message's wording, a name, a format), such as a ticket and the human naming a different log message; in doubt over a pure wording detail, it is small. Don't ask: the human's words win, and go into the spec draft.
- **No disagreement:** go on.
