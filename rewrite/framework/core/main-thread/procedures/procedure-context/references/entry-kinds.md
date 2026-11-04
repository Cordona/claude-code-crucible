# Entry kinds

How SKILL.md step 1 enters the entries that need their own route, and how step 6 writes a local commit as a file. Read it only when an entry is a Claude Code task id, a URL on a Jira, GitHub or GitLab host, or a commit SHA (7–40 hex characters) or range (`a..b`) from a local repository.

## In step 1

- **A Claude Code task** is a path entry: its file, `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/tasks/<list>/<n>.json`.
- **A Jira link:** load `procedure-jira-auth` with the Skill tool for its site and account check. If it can't be loaded, tell the human to install it under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/`, and leave the link out until it is.
- **A GitHub or GitLab link** is read through the `gh` or `glab` login that `read-link.sh --help` names; no skill is loaded for it.
- **A local commit or range:** SKILL.md step 6 writes it as a file (below). A remote commit or pull request is a link.

## A local commit or range as a file (step 6)

Run `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-context/scripts/context.sh" diff --effort '<effort folder>' --repo '<repository root>' --ref '<sha or range>'`.

- 0 with a `DIFF_FILE:` line: enter that path as a `--path` in SKILL.md step 4's or step 5's call, its why naming the commit and the repository. Without that line: as any other exit.
- Any other exit: as SKILL.md step 4's last two bullets set.
