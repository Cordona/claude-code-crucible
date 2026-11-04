# Tracker links

How the main thread reads each tracker link (a GitHub, GitLab or Jira issue).

Run `read-link.sh --help` once, before its first use in a session; run it again in that session only when its contract is no longer in context (after a compaction). Every other call runs only the command its step names. If `--help` exits non-zero or prints no `usage:` line, no tracker link is read: show the line `Tracker links are not read: read-link.sh could not run.`, word for word without its backticks and in a message of its own, and weigh the others without them. `<read-link.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-read-trackers/scripts/read-link.sh"`. Per link, one of its two forms:

- **In discovery, before any version:** `<read-link.sh> --url '<link>'`, the link quoted as CLAUDE.md sets, never through a shell variable.
- **After v1, a link in a written version:** `<read-link.sh> --context-file <the CONTEXT_FILE path> --link <n>`, `<n>` the link's place in that version's `links`, counting from 1.

Act on its exit, the same for both forms:

- **Read-only** (SKILL.md Never).
- **Exit 0:** stdout is the ticket; weigh it like the other entries. After v1, when the ticket changes the approved spec's goal, done-when or scope (with a recorded skip, the work's), run SKILL.md's The spec alone for its revised or new spec's offer.
- **Exit 3:** not a tracker link: read it with WebFetch, guided by its why.
- **Exit 1, any other exit, or the script missing** (`procedure-read-trackers` not installed): the link is not read; show the line `Link <the link, or n> was not read (read-link.sh exit <code>).`, as the line above is shown, and weigh the others without it.
