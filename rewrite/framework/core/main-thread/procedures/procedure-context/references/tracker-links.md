# Tracker links

How the main thread reads each tracker link (a GitHub, GitLab or Jira issue); read at SKILL.md step 1, when the human names one in discovery, or at step 5, when an extension after v1 adds one.

Kept here, not left to `procedure-read-trackers`: the main thread has loaded no plugin (a plugin reaches only a first message), and it acts on the exits differently.

Run `read-link.sh --help` once, before its first use in a session, and not again in that session unless its contract is no longer in context (after a compaction); every other call runs only the command its step names. A non-zero exit, or no `usage:` line: no tracker link is read; show the line `Tracker links are not read: read-link.sh could not run.`, word for word without its backticks and in a message of its own, and weigh the others without them, as the last bullet below sets. `<read-link.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-read-trackers/scripts/read-link.sh"`. Per link, one of its two forms:

- **In discovery, before any version:** `<read-link.sh> --url '<link>'`, the link quoted as CLAUDE.md sets, never through a shell variable.
- **After v1, a link in a written version:** `<read-link.sh> --context-file <the CONTEXT_FILE path> --link <n>`, `<n>` the link's place in that version's `links`, counting from 1.

Act on its exit, the same for both forms:

- **Read-only** (SKILL.md Never).
- **Exit 0:** stdout is the ticket; weigh it as the other entries. After v1, a ticket that changes the approved spec's goal, done-when or scope: run SKILL.md's The spec alone, for its revised spec's offer.
- **Exit 3:** not a tracker link: read it with WebFetch, guided by its why.
- **Exit 1, any other exit, or the script missing** (`procedure-read-trackers` not installed): the link is not read; show the line `Link <the link, or n> was not read (read-link.sh exit <code>).`, as the line above is shown, and weigh the others without it. Exit 4 comes only from the `--context-file` form.
