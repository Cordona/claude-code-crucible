# Plugin layout and the plugin list

What each plugin kind holds, and the contract of `scripts/list-plugins.sh`, which lists them. SKILL.md's Scripts section points here when a plugin line, a stderr line or an exit doesn't match what step 2 expects, or when a plugin's folder or frontmatter is in question. The skills folder below is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/`.

## What each kind holds

- **Tech plugin:** the source folder `software-development/shared/plugins/tech/<stack>/`, installed as `tech-<stack>` under the skills folder, with `name: tech-<folder>`, `disable-model-invocation: true` and `user-invocable: false`, so it never loads on its own: it arrives only through the hook. Its frontmatter's `metadata.label` (required) is the stack's display name, such as `Shell`.
- **Standard plugin:** the source folder `software-development/shared/plugins/standards/<area>/`, installed as `standard-<area>` under the skills folder, with `name: standard-<folder>`, `disable-model-invocation: true`, `user-invocable: false` and a required `metadata.label`, such as `Clean code`; it names no base. It arrives through the hook, or through the main thread's own reads at step 10.
- **Every plugin's `description`** (required) says what it covers and, under "Not for …", what it excludes; SKILL.md's step 4 picks by it.
- **Not a plugin:** a `standard-*` folder whose closed frontmatter lacks `disable-model-invocation: true` is not a plugin: skipped, never reported as invalid. Examples: an old preloaded standard not yet rewritten, or an agent's own skill, such as `standard-code-development-report`.
- **An agent's own skills:** they live in its folder, `software-development/agents/<agent>/skills/<name>/`, never under `shared/`.
- **Files, every plugin:** `SKILL.md` (the rules every role receives) and `<plugin>/references/development.md` (developers); optional: `<plugin>/references/review.md` (reviewers, once `code-reviewer` exists, #64) and `<plugin>/references/*-template.md` files (developers).
- **Base plugin (tech only):** `metadata.base` in `SKILL.md`'s frontmatter, naming another tech plugin's stack (`typescript` for React); left out when there is none. One level only: a base sets no `metadata.base` of its own.

## The plugin list script

`scripts/list-plugins.sh` lists the installed plugins. Run it with Bash; the main thread runs it at step 2, and `render-plugin-line.sh` runs it at steps 7, 9 and 10; a developer or reviewer never does.

- **Command:** `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-agent-initialization/scripts/list-plugins.sh" --max-lines 0 [--skills-dir DIR]`; `--skills-dir` replaces the installed skills folder.
- **Stdout:** one TAB-separated line per valid plugin, tech lines first, then standard lines, each sorted by name: `<kind> <name> <label> <description> [<base SKILL.md> <base development.md>] <SKILL.md> <development.md>`.
  - `<kind>` is `tech` or `standard`; `<name>` the plugin's full folder name, such as `tech-shell`; `<label>` its `metadata.label`, never empty; `<description>` its frontmatter `description`, unquoted, each tab or newline turned into one space, never empty.
  - The paths start at field 5. The two base paths appear only for a tech plugin whose `metadata.base` names a base; every path is absolute.
  - Sample (TAB shown as `\t`, illustrative path, description cut here): `tech\ttech-shell\tShell\tShell (Bash and POSIX sh) rules for writing scripts … Not for shell embedded in another file …\t/home/u/.claude/skills/tech-shell/SKILL.md\t/home/u/.claude/skills/tech-shell/references/development.md`
- **The paths are the developer's, without templates:** `render-plugin-line.sh --role developer` adds each plugin's `<plugin>/references/*-template.md` files; `--role reviewer` puts each plugin's `<plugin>/references/review.md` in place of its `<plugin>/references/development.md`.
- **Size:** `--max-lines N` caps stdout at N plugin lines (default 200; 0 prints all). Pass `--max-lines 0`: a plan needs every plugin. When lines are cut, stderr gets `list-plugins.sh: TRUNCATED: showing N of M plugin lines; pass --max-lines 0 for all`, and the exit code is unchanged.
- **Stderr:** diagnostics only; each invalid plugin gets one line, `list-plugins.sh: <name>: <reason>`, and no stdout line.
- **Skipped, not a plugin:** a `standard-*` folder whose closed frontmatter lacks `disable-model-invocation: true` is skipped, never reported as invalid.
- **Invalid (exit 3), never listed:** only a real plugin folder that fails the rules: the hook's plugin test (name = folder, `disable-model-invocation: true`, closed frontmatter); a missing file, `metadata.label` or `description`; a standard with `metadata.base`; a tech base that is invalid, missing or nested; a plugin path (folder name, base folder or skills folder) holding a comma or control character, which would split the `PLUGIN` line or a plugin line (a control character in the stderr line shows as `?`). A `standard-*` folder with no SKILL.md or an unclosed frontmatter counts as invalid, since its opt-in can't be read. The hook's file checks (expansion tokens, closing line, containment, readability) run at dispatch; a failure comes back through SKILL.md's step 9.
- **Exit codes:** 0 ok · 1 no plugin installed · 2 usage error, or the skills folder missing or unreadable · 3 one or more invalid plugins (the valid ones are still printed) · 5 a required tool (`awk` or `sort`) missing.
- **Dependencies:** POSIX `sh`, `awk` and `sort`, in every macOS and Linux base system; the script checks them at start and exits 5 naming the missing one.
- **Runtime:** well under a second (0.08 s measured over the installed skills folder); it reads only each plugin's `SKILL.md` frontmatter, so it grows with the plugin count.
