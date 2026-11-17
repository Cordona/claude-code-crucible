# Tracker links

How the main thread reads each tracker link (a GitHub, GitLab or Jira issue).

If `read-link.sh --help` exits non-zero or prints no `usage:` line, no tracker link is read: show the line `tracker_links_not_read`, and weigh the others without them. `<views>` is as SKILL.md sets. `<read-link.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-read-trackers/scripts/read-link.sh"`. Per link, one of its two forms:

- **A link not yet in a cut version** (in discovery, or added after a cut): `<read-link.sh> --url '<link>'`, never through a shell variable.
- **A link in a cut version:** `<read-link.sh> --context-file '<the CONTEXT_FILE path>' --link <n>`, `<n>` the link's place in that version's `links`, counting from 1.

Act on its exit, the same for both forms:

- **Read-only** (SKILL.md Never).
- **Exit 0:** stdout is the ticket; weigh it like the other entries. After the spec is approved, when the ticket changes its goal, done-when or scope, run SKILL.md's The spec alone for its revision offer.
- **Exit 3:** not a tracker link: read it with WebFetch, guided by its why.
- **Exit 1, any other exit, or the script missing** (`procedure-read-trackers` not installed): the link is not read; show the line `link_not_read`, with `--arg link '<the link, or n>' --arg code '<code>'`, and weigh the others without it.
