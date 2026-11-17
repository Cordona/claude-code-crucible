# Reserved names — bundled skills and built-in commands

The pinned list LNT-08 compares a skill or command name against. Compare after LNT-08's normalization (NFKC, casefold, drop whitespace and the zero-width characters U+200B–U+200D and U+FEFF); a match is a collision.
The docs give these as examples, not as an exhaustive list, so a name absent here is not proven free. Re-check both sources after a Claude Code update and re-date each checked row.

## Contents

- Bundled skills (version ledger)
- Built-in commands (version ledger)

## Bundled skills (version ledger)

| Name | Note | Source | Checked |
|---|---|---|---|
| `doctor` | alias `checkup` | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `checkup` | alias of `doctor` | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `code-review` | alias `review` | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `review` | alias of `code-review` | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `batch` | | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `debug` | | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `loop` | | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `claude-api` | | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `verify` | LNT-08 FAILs it unless a waiver states the pre-commit behavior is intended | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `run` | | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `run-skill-generator` | | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `simplify` | LNT-08 FAILs it unless a waiver states the pre-commit behavior is intended | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `workflow-authoring` | only with dynamic workflows | https://code.claude.com/docs/en/skills.md (Bundled skills) | 2026-10-13 |
| `artifact-capabilities` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |
| `artifact-diagramming` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |
| `claude-in-chrome` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |
| `dataviz` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |
| `design` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |
| `design-sync` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |
| `fewer-permission-prompts` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |
| `slides` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |
| `update-config` | tagged [Skill] in the commands table | https://code.claude.com/docs/en/commands.md | 2026-10-13 |

## Built-in commands (version ledger)

Every row: source https://code.claude.com/docs/en/commands.md (the commands table), checked 2026-10-13.

| Name | Source | Checked |
|---|---|---|
| `add-dir` | commands.md | 2026-10-13 |
| `advisor` | commands.md | 2026-10-13 |
| `agents` | commands.md | 2026-10-13 |
| `artifacts` | commands.md | 2026-10-13 |
| `auto-mode-setup` | commands.md | 2026-10-13 |
| `autocompact` | commands.md | 2026-10-13 |
| `autofix-pr` | commands.md | 2026-10-13 |
| `background` | commands.md | 2026-10-13 |
| `branch` | commands.md | 2026-10-13 |
| `btw` | commands.md | 2026-10-13 |
| `bug` | commands.md | 2026-10-13 |
| `cd` | commands.md | 2026-10-13 |
| `chrome` | commands.md | 2026-10-13 |
| `clear` | commands.md | 2026-10-13 |
| `color` | commands.md | 2026-10-13 |
| `compact` | commands.md | 2026-10-13 |
| `config` | commands.md | 2026-10-13 |
| `context` | commands.md | 2026-10-13 |
| `copy` | commands.md | 2026-10-13 |
| `cost` | commands.md | 2026-10-13 |
| `design-login` | commands.md | 2026-10-13 |
| `desktop` | commands.md | 2026-10-13 |
| `diff` | commands.md | 2026-10-13 |
| `effort` | commands.md | 2026-10-13 |
| `exit` | commands.md | 2026-10-13 |
| `export` | commands.md | 2026-10-13 |
| `fast` | commands.md | 2026-10-13 |
| `feedback` | commands.md | 2026-10-13 |
| `focus` | commands.md | 2026-10-13 |
| `fork` | commands.md | 2026-10-13 |
| `goal` | commands.md | 2026-10-13 |
| `heapdump` | commands.md | 2026-10-13 |
| `help` | commands.md | 2026-10-13 |
| `hooks` | commands.md | 2026-10-13 |
| `ide` | commands.md | 2026-10-13 |
| `import` | commands.md | 2026-10-13 |
| `init` | commands.md | 2026-10-13 |
| `insights` | commands.md | 2026-10-13 |
| `install-github-app` | commands.md | 2026-10-13 |
| `install-slack-app` | commands.md | 2026-10-13 |
| `keybindings` | commands.md | 2026-10-13 |
| `list-agents` | commands.md | 2026-10-13 |
| `login` | commands.md | 2026-10-13 |
| `logout` | commands.md | 2026-10-13 |
| `mcp` | commands.md | 2026-10-13 |
| `memory` | commands.md | 2026-10-13 |
| `mobile` | commands.md | 2026-10-13 |
| `model` | commands.md | 2026-10-13 |
| `output-style` | commands.md | 2026-10-13 |
| `passes` | commands.md | 2026-10-13 |
| `permissions` | commands.md | 2026-10-13 |
| `plan` | commands.md | 2026-10-13 |
| `plugin` | commands.md | 2026-10-13 |
| `plugin-authoring` | commands.md | 2026-10-13 |
| `powerup` | commands.md | 2026-10-13 |
| `pr-comments` | commands.md | 2026-10-13 |
| `privacy-settings` | commands.md | 2026-10-13 |
| `radio` | commands.md | 2026-10-13 |
| `rate-limit-options` | commands.md | 2026-10-13 |
| `recap` | commands.md | 2026-10-13 |
| `release-notes` | commands.md | 2026-10-13 |
| `reload-plugins` | commands.md | 2026-10-13 |
| `reload-skills` | commands.md | 2026-10-13 |
| `remote-control` | commands.md | 2026-10-13 |
| `remote-env` | commands.md | 2026-10-13 |
| `rename` | commands.md | 2026-10-13 |
| `resume` | commands.md | 2026-10-13 |
| `review` | commands.md | 2026-10-13 |
| `rewind` | commands.md | 2026-10-13 |
| `sandbox` | commands.md | 2026-10-13 |
| `schedule` | commands.md | 2026-10-13 |
| `scroll-speed` | commands.md | 2026-10-13 |
| `security-review` | commands.md | 2026-10-13 |
| `setup-bedrock` | commands.md | 2026-10-13 |
| `setup-vertex` | commands.md | 2026-10-13 |
| `skill-doctor` | commands.md | 2026-10-13 |
| `skills` | commands.md | 2026-10-13 |
| `stats` | commands.md | 2026-10-13 |
| `status` | commands.md | 2026-10-13 |
| `statusline` | commands.md | 2026-10-13 |
| `stickers` | commands.md | 2026-10-13 |
| `stop` | commands.md | 2026-10-13 |
| `subtask` | commands.md | 2026-10-13 |
| `tasks` | commands.md | 2026-10-13 |
| `team-onboarding` | commands.md | 2026-10-13 |
| `teleport` | commands.md | 2026-10-13 |
| `terminal-setup` | commands.md | 2026-10-13 |
| `theme` | commands.md | 2026-10-13 |
| `tui` | commands.md | 2026-10-13 |
| `ultraplan` | commands.md | 2026-10-13 |
| `ultrareview` | commands.md | 2026-10-13 |
| `upgrade` | commands.md | 2026-10-13 |
| `usage` | commands.md | 2026-10-13 |
| `usage-credits` | commands.md | 2026-10-13 |
| `vim` | commands.md | 2026-10-13 |
| `voice` | commands.md | 2026-10-13 |
| `web-setup` | commands.md | 2026-10-13 |
| `workflows` | commands.md | 2026-10-13 |
