# Tracker links

How the main thread reads each tracker link (a GitHub, GitLab or Jira issue) in a written context version; read at SKILL.md step 4, or step 5, when the version holds a tracker link.

Kept here, not left to `procedure-read-trackers`: the main thread has loaded no plugin (a plugin reaches only a first message), and it acts on the exits differently.

`read-link.sh` reads a link from a written context version, so the tracker links are read once SKILL.md's step 4 or step 5 has written it. Run `read-link.sh --help` once, before its first use in a session, and not again in that session unless its contract is no longer in context (after a compaction); every other call runs only the command its step names. A non-zero exit, or no `usage:` line: no tracker link is read; show the line `Tracker links are not read: read-link.sh could not run.`, word for word without its backticks and in a message of its own, and weigh the others without them, as the last bullet below sets. Per link:

`sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-read-trackers/scripts/read-link.sh" --context-file <the CONTEXT_FILE path> --link <n>`

- **`<n>`:** the link's place in that version's `links`, counting from 1.
- **Read-only** (SKILL.md Never).
- **Exit 0:** stdout is the ticket; weigh it as the other entries.
- **Exit 3:** not a tracker link: read it with WebFetch, guided by its why.
- **Exit 1, any other exit, or the script missing** (`procedure-read-trackers` not installed): the link is not read; show the line `Link <n> was not read (read-link.sh exit <code>).`, as the line above is shown, and weigh the others without it.
