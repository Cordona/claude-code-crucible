# Lint spec — mechanical skill checks

Spec for the mechanical checks on skills, agents and the collection; `scripts/lint.sh` runs the per-artifact ones (Scope, below). Every countable rule lives here, not in the checklists.

## Contents

- Terms and output
- A. Gate (LNT-00)
- B. Files and frontmatter (LNT-01 – LNT-14, LNT-49, LNT-63, LNT-64)
- C. Body size and text (LNT-15 – LNT-26, LNT-70, LNT-73)
- D. Scripts (LNT-27 – LNT-30, LNT-32, LNT-37, LNT-47)
- E. Hooks (LNT-33, LNT-34)
- F. Binding, permissions, collection (LNT-31, LNT-35, LNT-36, LNT-40 – LNT-46, LNT-48, LNT-50, LNT-65)
- G. Evals and examples (LNT-38, LNT-39, LNT-51)
- H. Schemas and agent cards (LNT-52 – LNT-58)
- I. Agent files (LNT-59 – LNT-62, LNT-66 – LNT-69, LNT-71, LNT-72)

## Terms and output

- **Skill dir:** a repo dir containing `SKILL.md`. **Deployed name:** its symlink name in `~/.claude/skills/`; when the dir basename is `skill`, the parent dir name.
- **Frontmatter:** lines between line 1 `---` and the next `---`. **Body:** everything after it.
- **Collection:** all skill dirs, `~/.claude/commands/**/*.md`, agent files (`.md` files with frontmatter under an `agents/` dir, excluding `SKILL.md` and anything inside a skill dir — skills also live under `agents/<agent>/skills/`), and `~/.claude/CLAUDE.md` (LNT-46 only).
- **Code region:** fenced blocks and inline code spans; text checks skip them unless stated.
- **Gate hook:** a hook on PreToolUse, UserPromptSubmit, UserPromptExpansion, Stop or SubagentStop that the skill describes as enforcing a rule.
- **Artifact dirs:** a skill or agent dir holds only the artifact's own files; anything else in it is still linted by LNT-47.
- **Characters:** Unicode code points, counted after stripping a trailing `\r`. **Tokens:** `ceil(chars / 4)` (swap in a tokenizer when available).
- **Agent body:** everything after an agent file's frontmatter. **Description length:** the parsed value; a folded or literal block is joined as YAML would join it.
- **Tier:** where an item's threshold comes from — `official` (Anthropic's docs or the Agent Skills spec) or `ours` (an owner decision).
- **Output:** one line per finding `LNT-NN PASS|FAIL|WARN|INFO <file>:<line> <message>`, at most `--max-lines` per target (then `TRUNCATED INFO <target> showing <N> of <M> lines`), then `SUMMARY must_fail=<n> should_fail=<n> warn=<n> skipped_must=<n> files=<n>`.
- **SHOULD FAIL:** never fails the run; it is listed for the owner.
- **Waiver:** a line in the target's waivers file, as `SKILL.md` Invariants define it, passed with `--waivers`; `lint.sh` honours it only for a `SHOULD` or `MAY` `LNT-NN` item.
- **INFO:** reports a measured value and never fails.
- **Exit codes:** 0 no MUST FAIL · 1 at least one MUST FAIL · 2 usage error · 3 no MUST FAIL, but a MUST item skipped for a missing optional tool · 4 rulebook not found · 5 internal error, or a required tool missing · 130 or 143 interrupted (INT or TERM). `SKILL.md`'s Scripts section repeats them for callers, as SCR-01 requires; change both together.
- **Report-only run:** every item runs and prints as usual, and findings (a MUST FAIL or a skipped MUST) exit 0; exits 2, 4 and 5 are unchanged. Use it on artifacts not yet brought up to the rulebook, so the run lists their findings without failing.
- **Scope:** `scripts/lint.sh` judges one skill or one agent (it may read the files that artifact references, e.g. its preloads); collection items — those whose Files name the collection (LNT-08, LNT-35, LNT-42, LNT-46, LNT-65) and the uniqueness clause of LNT-59 — are not run by `lint.sh`.
- **Collection items gate nothing collection-wide.**
- **A reviewer hand-checks the target's own part of a collection item** (`SKILL.md`, Reviewer report format).
- **When it runs:** `flow-harness-authoring` runs `lint.sh` on the target before seating the reviewer swarm (Skill flow step 5, Agent flow step 4).

## A. Gate

- **LNT-00** · MUST · Files: every changed skill dir and agent file · How: run every item on each before merge and deploy · Threshold: zero MUST FAILs; every SHOULD FAIL listed for the owner (fixed or waived).

## B. Files and frontmatter

- **LNT-01** · MUST · Files: skill dir · How: a file named exactly `SKILL.md` exists · Threshold: present.
- **LNT-02** · MUST · Files: `SKILL.md` · How: line 1 is `---` and a later line is `---` · Threshold: both.
- **LNT-03** · MUST · Files: frontmatter · How: YAML-parse to a mapping; a plain (non-block, unquoted) scalar containing `: ` FAILs; cross-check with `claude plugin validate <skills dir>` where available · Threshold: parses, zero unquoted `: `.
- **LNT-04** · MUST · Files: frontmatter · How: `name` and `description` exist as non-empty strings · Threshold: both.
- **LNT-05** · MUST · Files: frontmatter · How: `name` matches `^[a-z0-9]+(-[a-z0-9]+)*$` · Threshold: match, ≤ 64 chars · Tier: official (spec name format).
- **LNT-06** · MUST · Files: skill dir · How: `name` equals the deployed name (Terms) · Threshold: equal · Tier: official (spec: name matches its dir).
- **LNT-07** · MUST · Files: frontmatter, dir name · How: `name` lacks `anthropic`/`claude`; dir is not `synced` (any case) or `anthropic-skills` · Threshold: none present · Tier: official (reserved words); the dir names are ours.
- **LNT-08** · MUST · Files: collection + the pinned list of bundled skills and built-in commands in `references/shared/reserved-names.md` · How: normalize (NFKC, casefold, drop whitespace and U+200B–U+200D, U+FEFF) and compare; `verify` and `simplify` FAIL unless a waiver states the pre-commit behavior is intended · Threshold: zero collisions.
- **LNT-09** · MUST · Files: frontmatter · How: `len(description)`; re-run after every description edit · Threshold: ≤ 1,024 · Tier: official (spec maximum).
- **LNT-10** · MUST · Files: frontmatter · How: `<` or `>` in `description` · Threshold: zero.
- **LNT-11** · SHOULD · Files: frontmatter · How: `len(description) + len(when_to_use)` · Threshold: ≤ 1,536.
- **LNT-12** · MUST · Files: frontmatter · How: keys ⊆ {name, description, when_to_use, argument-hint, arguments, disable-model-invocation, user-invocable, allowed-tools, disallowed-tools, model, effort, context, agent, background, hooks, paths, shell, license, compatibility, metadata}; any other key FAILs, since Claude Code ignores an unknown field silently and a typo disables the setting; agent-only keys (tools, disallowedTools, skills, maxTurns, permissionMode, mcpServers) and `version` FAIL; booleans take true/false/yes/no/on/off/1/0 · Threshold: zero violations · Tier: official (unknown fields ignored); the set is the Claude Code skill field list.
- **LNT-13** · MUST · Files: frontmatter · How: `compatibility`, if present, is 1–500 chars; `metadata` not a string→string map, or reusing a field name as key, WARNs · Threshold: compatibility in range.
- **LNT-14** · MUST · Files: frontmatter · How: outside quoted spans (`"…"`, `'…'`, backticks — quoted user phrasings may be first person), case-insensitive `\bI\b(?!/)` (so `I/O` passes), `\bI'(m|ll|ve)\b`, `\bmy\b`, `\bwe\b`, `\bour\b`, `\byou can\b`, `\byou could\b` in `description` · Threshold: zero · Tier: official (descriptions in third person).
- **LNT-49** · SHOULD · Files: `SKILL.md` · How: `description` length; body non-heading, non-blank lines · Threshold: ≥ 50 chars; ≥ 1 line.
- **LNT-63** · SHOULD · Files: frontmatter · How: `len(description)` · Threshold: ≤ 500 · Tier: ours (near Anthropic's own skill descriptions; keeps the listing within LNT-42).
- **LNT-64** · MUST · Files: `SKILL.md` frontmatter · How: every key in REQUIRED is present with a non-empty value (YAML booleans count as values; only a missing key, null or "" is empty). The lint holds the list itself. REQUIRED: `name`, `description`. Every other key in LNT-12's set may be absent (its documented default applies); the authors' field table is where each optional field is decided · Threshold: both REQUIRED keys present · Tier: ours (a default written out is visible and can be changed per skill).

## C. Body size and text

- **LNT-15** · SHOULD · Files: `SKILL.md` body · How: tokens (Terms) · Threshold: ≤ 5,000 · Tier: official (recommendation).
- **LNT-16** · SHOULD · Files: `SKILL.md` body · How: line count · Threshold: ≤ 500 · Tier: official (recommendation).
- **LNT-17** · SHOULD · Files: skill dir · How: every file except `SKILL.md`, dotfiles, `evals/**` and build-junk dirs (`__pycache__/`, `node_modules/`) is named (path or basename) in `SKILL.md` or in a script that is · Threshold: zero orphans.
- **LNT-18** · SHOULD · Files: `*.md` other than `SKILL.md` in the skill dir · How: links or path mentions of another `.md` in the same skill (a link back to `SKILL.md`, or a mention of the convention name `SKILL.md`, is fine) · Threshold: zero · Tier: official (references one level deep).
- **LNT-19** · SHOULD · Files: reference `*.md` (not `SKILL.md`, which loads whole) · How: if > 100 lines, the first 20 lines hold a heading matching `/contents/i` or ≥ 3 bullets naming later headings · Threshold: present · Tier: official (recommendation).
- **LNT-20** · MUST · Files: `*.md` in the skill dir · How: a path-shaped token with `\` as separator — ends in a known extension (`.sh .py .js .ts .md .json .jq .yaml`) or starts with `scripts|references|assets|examples|lib` · Threshold: zero.
- **LNT-21** · MUST · Files: `SKILL.md` body, code regions included · How: `\$([0-9]|ARGUMENTS\b|<declared argument names>\b)` not preceded by exactly one `\` (`\\$1` counts as unescaped); in a skill preloaded by any agent every hit FAILs (preloading blanks `$ARGUMENTS`); otherwise only lines marked `<!-- lint: placeholder -->` are exempt. Positional placeholders are 0-based (`$0` = first argument) · Threshold: zero (escape a literal as `\$1`; verified).
- **LNT-22** · SHOULD · Files: skill dir · How: empty dirs; stems matching `^(file|doc|misc|utils?|helpers?|tools?|stuff|temp|tmp|untitled)\d*$`; placeholder-only files; build junk (`.DS_Store`, `__pycache__/`, `*.pyc`, `node_modules/`) · Threshold: zero.
- **LNT-23** · SHOULD · Files: `SKILL.md` body outside code regions and headings · How: uppercase tokens in {MUST, NEVER, ALWAYS, ONLY, NOT, NO, CRITICAL, IMPORTANT, REQUIRED} ÷ words × 100 · Threshold: ≤ 1.
- **LNT-24** · SHOULD · Files: `SKILL.md` and references outside code regions · How: `\b(as of|before|after|until|since)\s+(January|…|December|20\d\d)`, `\b(currently|recently|nowadays|new in)\b`, ISO dates · Threshold: zero outside an "Old patterns" or version-ledger section.
- **LNT-25** · MUST · Files: `SKILL.md` body · How: find the first heading matching `^#+\s*(\d+\.\s*)?(invariants|constraints)\b` (case-insensitive); its section runs to the next heading of the same or a higher level; take the char offset, from the body's start, of that section's end. After compaction an invoked skill keeps only its first 5,000 tokens · Threshold: ≤ 20,000 chars, or the whole body ≤ 20,000; a body over 20,000 with no such heading FAILs · Tier: official (compaction limit).
- **LNT-26** · MAY · Files: reference `*.md` · How: word count > 10,000 needs a `grep` pattern naming that file in `SKILL.md` · Threshold: present.
- **LNT-70** · SHOULD · Files: `SKILL.md` body, reference `*.md`, agent bodies · How: outside code regions, headings, table rows and HTML comments, split prose into sentences at `.`, `!` or `?` followed by whitespace or line end, and at the end of each list item and paragraph; never after `e.g.`, `i.e.`, `etc.`, `vs.` or a period between digits. Words are whitespace-separated tokens holding a letter or digit; take the median word count over sentences of ≥ 1 word; print it, with the sentence count, as an INFO line for every file · Threshold: median ≤ 25 · Tier: ours (near Anthropic's own files; there is no official sentence or word limit).
- **LNT-73** · MUST · Files: `SKILL.md` body, reference `*.md`, agent bodies · How: outside code regions, a line of leading whitespace, then `\d+[.)]` and a space, that comes after an ordered-list item, either with no blank line or heading between them or with only blank lines between them, is a nested ordered item and FAILs: Markdown renders it as i, ii or a, b · Threshold: zero; write each sub-step as its own line numbered `N.1`, `N.2` (for example an indented paragraph starting `**7.1 …**`), with its cases as plain `-` bullets.

## D. Scripts

- **LNT-27** · SHOULD · Files: `scripts/**`, `lib/**` with a shebang · How: executable bit; entry-point scripts print a `usage:` line on `--help`/`-h` and on no arguments · Threshold: all.
- **LNT-28** · MUST · Files: scripts · How: `read -p`, `read -s`, `/dev/tty`, `\bselect\b .* in`, `getpass`, `input(`, `readline.createInterface`, `prompt(`, `confirm(` · Threshold: zero.
- **LNT-29** · SHOULD · Files: shell scripts · How: bash shebang → `set -euo pipefail` (or `-Eeuo`) in the first 30 lines; `sh` shebang → `set -eu` (no `pipefail`); exception marker `# lint: no-strict-mode <reason>`; `shellcheck` exits 0 · Threshold: all.
- **LNT-30** · MUST · Files: `SKILL.md` and references · How: extract relative Markdown link targets, path tokens (at a token boundary) whose first segment is a dir in the skill dir, and `${CLAUDE_SKILL_DIR}/…`, `$HOME/.claude/skills/<name>/…`, `~/.claude/skills/<name>/…`; resolve against the skill root, then `scripts/`; `<name>` resolves to its repo dir · Threshold: every path exists; ambiguous or unresolvable prefixes WARN.
- **LNT-32** · SHOULD · Files: scripts · How: a literal `/tmp/<name>` path FAILs; `mktemp` without `trap … EXIT` FAILs · Threshold: zero.
- **LNT-37** · SHOULD · Files: `SKILL.md` and references, code regions · How: a command line starting `scripts/`, `./scripts/` or `<interpreter> scripts/`; `${CLAUDE_SKILL_DIR}` in a skill named in any agent's `skills:` outside `!` lines · Threshold: zero.
- **LNT-47** · MUST · Files: every text file in skill dirs and agent files · How: private-key headers (`-----BEGIN [A-Z ]*PRIVATE KEY`), `AKIA[0-9A-Z]{16}`, `gh[pousr]_[A-Za-z0-9]{36}`, `glpat-[A-Za-z0-9_-]{20}`, `xox[baprs]-`, values ≥ 20 high-entropy chars assigned to `token|secret|password|api_key`; allow `<placeholder>` forms and lines marked `lint: example-secret` · Threshold: zero.

## E. Hooks

- **LNT-33** · MUST · Files: `hooks:` in skill and agent frontmatter · How: documented events only; handler `type` allowed for the event (SessionStart/Setup: command, mcp_tool; SubagentStart, ConfigChange, PreCompact: no prompt/agent; PermissionRequest: no agent); no `matcher` on UserPromptSubmit, Stop, PostToolBatch, TaskCreated, TaskCompleted, TeammateIdle, Worktree*, MessageDisplay, CwdChanged; a matcher with chars outside `[A-Za-z0-9_ ,|-]` (FileChanged/StopFailure: outside `[A-Za-z0-9_|]`) is anchored `^…$` unless exactly `mcp__<server>__.*`; `^mcp__[^_]+(__)?$` without `.*` FAILs; `if` only on tool events; `once` only in skill frontmatter · Threshold: zero.
- **LNT-34** · MUST · Files: scripts named in frontmatter hook commands · How: the lint judges the whole script, not only its hook path, so such a script keeps any other mode (a `--flag` the main thread runs, such as `--direct`) and any literal deny for a missing `jq` in a separate script; in a gate hook, any `exit N` with N ∉ {0, 2} FAILs; `set -e` without `set -E` and an `ERR` trap that exits 2 FAILs; a Stop/SubagentStop script must read `stop_hook_active` before its first dependency check (`command -v`, `jq`) and exit 0 when true; on a matcher-less event (UserPromptSubmit, Stop) the trap may exit 2 only after an in-script guard has matched — otherwise WARN; `echo '{`/`printf '{` JSON FAILs (use `jq`); `"allow"` or `updatedInput` in output WARNs for HK-12 · Threshold: zero FAILs.

## F. Binding, permissions, collection

- **LNT-31** · MUST · Files: `SKILL.md` body · How: each `` !`cmd` `` (line start or after whitespace) and each ` ```! ` line is matched by an `allowed-tools` `Bash(<glob>)` · Threshold: all.
- **LNT-35** · MUST · Files: collection · How: a skill with a house prefix (flow-, procedure-, standard-, review-, build-, harness-, code-development-, code-review-), named in any agent `skills:` list, or named in backticks in `~/.claude/CLAUDE.md` or another skill/agent body, does not set `disable-model-invocation: true` (`user-invocable: false` is not checked); a plugin (a `tech-` skill, a `standard-` skill under `plugins/standards/`, or a `procedure-` skill under `plugins/procedures/`) is exempt, since it is read by path only and sets it by design; a `procedure-` skill elsewhere is not a plugin · Threshold: zero.
- **LNT-36** · MUST · Files: agent files · How: each `skills:` entry resolves to a skill in the collection · Threshold: all.
- **LNT-40** · SHOULD · Files: skill frontmatter · How: skill `name` starts with a house prefix (owner may extend) and its words are not only generic (`helper`, `utils`, `tools`, `documents`, `data`, `files`) · Threshold: all.
- **LNT-41** · MUST · Files: skill `allowed-tools` only (it pre-approves, it does not restrict) · How: `Bash`, `Bash(*)`, `Bash(* *)` FAIL; unscoped `Write`/`Edit` WARN · Threshold: zero FAILs.
- **LNT-42** · SHOULD · Files: collection skills and `~/.claude/commands/**/*.md` · How: (a) sum, over every entry, `len(name) + min(len(description) + len(when_to_use), 1536)`; print the total, the budget and the five longest entries as INFO on every run. Budget: 1% of the house model's context window (1,000,000 tokens, frontmatter-fields Versions table) × 4 chars per token = 40,000 chars; a smaller window is passed as an option. A skill with `disable-model-invocation: true` counts its name only (its description is not in context). On overflow Claude Code drops the descriptions of the least-used skills, and a skill without one appears to go unused. (b) By hand, live: enabled plugin skills and bundled skills share the budget but are outside the collection, so read the Skills row of `/context`; an entry listed by name only means a description was dropped · Threshold: (a) total ≤ the budget (40,000 chars by default); (b) none dropped; fix by trimming, or by raising `skillListingBudgetFraction` with a waiver · Tier: official (1% budget, dropped descriptions).
- **LNT-43** · SHOULD · Files: `SKILL.md` and references · How: an MCP tool written `<Server>:<tool>` instead of `mcp__<server>__<tool>` · Threshold: zero.
- **LNT-44** · SHOULD · Files: repo diff · How: new files under any `.claude/commands/` · Threshold: zero.
- **LNT-45** · SHOULD · Files: `.gitignore` · How: `evals/results/` (or the configured results dir) listed when plugin evals exist · Threshold: present.
- **LNT-46** · MUST · Files: collection including `~/.claude/CLAUDE.md` · How: every `` `<skill>` §<N>[a-z]? `` (also `` `<skill>`'s §N ``) resolves to a heading in that skill numbered `N` (`## N.` or `### Na.`); a moved or renumbered section must update every citer in the same change · Threshold: all resolve.
- **LNT-48** · MUST · Files: agent files · How: `name` matches `^[a-z0-9]+(-[a-z0-9]+)*$`, 3–50 chars, equals the file stem · Threshold: all · Tier: ours.
- **LNT-50** · MUST · Files: agent files under `agents/reviewers/` and any agent whose name or file stem ends `-reviewer`, `-arbiter` or `-grader` · How: `tools` contains none of Write, Edit, NotebookEdit, Bash · Threshold: zero.
- **LNT-65** · MUST · Files: collection agent files · How: sum the description lengths of every agent file; print the total in chars and tokens (Terms) as INFO on every run. Enabled plugin agents appear to count toward the same warning but are outside the collection, so leave headroom · Threshold: ≤ 15,000 tokens (60,000 chars) · Tier: official (Claude Code warns at startup above it).

## G. Evals and examples

- **LNT-38** · MUST · Files: `evals/**` · How: one format only (`evals/evals.json` XOR plugin-eval case dirs); `evals.json` has `skill_name` and `evals[]` each with `id`, `prompt`, `expected_output`, and one assertion field name (`assertions`) throughout; plugin-eval: each case has `prompt.md` and/or `case.yaml`, ≥ 1 grader, documented `prompt.md` keys only, `env` keys `EVAL_[A-Z0-9_]*`, `case.yaml` with `schema_version: "1.1"` and `name`, no `(?` inline regex flags · Threshold: zero violations.
- **LNT-51** · SHOULD · Files: `examples/**`, `assets/**`, fenced blocks tagged json/yaml/bash/sh/python in `SKILL.md` and references · How: `jq .` / YAML parse / `bash -n` + `shellcheck` / `python -m py_compile`; skip blocks marked illustrative · Threshold: all parse.
- **LNT-39** · SHOULD · Files: `evals/**` · How: count output cases; for model-invocable skills, trigger queries per `should_trigger` class · Threshold: ≥ 3 cases; ≥ 8 per class.

## H. Schemas and agent cards

- **Contract set:** the `*.schema.json` files a skill, its scripts or an agent it dispatches writes or reads, plus any file their validator reads. **Agent card:** `contracts/cards/<contract>.<agent>.md` (checklist 11, Terms).
- **LNT-52** · MUST · Files: contract set · How: every top-level `properties` entry of each payload object carries `x-writer` whose value, or each list element, is `script`, `orchestrator` or `agent:<name>`; nested entries inherit; `$defs` exempt · Threshold: all.
- **LNT-53** · MUST · Files: agent files, skills preloaded into them, and the briefs and templates this skill hands to agents (orchestrator-only text in `SKILL.md` exempt) · How: grep for the basenames of this skill's contract set (any path prefix, deployed or repo); text the orchestrator copies into a brief counts as a brief · Threshold: zero.
- **LNT-54** · MUST · Files: contract set, agent cards · How: every `agent:<name>` in an `x-writer` marker has a card; run the generator into a temp file and diff it against the stored card; while LNT-52 FAILs report `UNDECIDABLE (blocked by LNT-52)` · Threshold: every card present and identical.
- **LNT-55** · SHOULD · Files: agent cards · How: count characters · Threshold: ≤ 8,000.
- **LNT-56** · SHOULD · Files: contract set · How: each `description` length (the schema root included); `description` strings identical after whitespace normalization, and `pattern` strings sharing a 100-character substring, in two places · Threshold: root ≤ 400 characters, others ≤ 200; zero duplicates.
- **LNT-57** · MUST · Files: contract set · How: each agent-written `string` (an unmarked field counts as agent-written while LNT-52 FAILs) has an effective `maxLength`, `enum`, `const`, a `pattern` with only bounded quantifiers, or an id pattern `^X[0-9]+$` with `maxLength` ≤ 10; each agent-written `array` has an effective `maxItems`; all after resolving `$ref` and `allOf` · Threshold: all.
- **LNT-58** · SHOULD · Files: agent cards · How: generate twice and diff; grep for date, time and absolute-path patterns · Threshold: identical; zero matches.

## I. Agent files

- **LNT-59** · MUST · Files: agent files · How: YAML-parse the frontmatter; every key is one of `name`, `description`, `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`, `background`, `omitClaudeMd`, `effort`, `isolation`, `color`, `initialPrompt`, `experimental`; `name` and `description` are non-empty; `name` is unique across the agents tree; `effort` is one of `low`, `medium`, `high`, `xhigh`, `max`; `color` is one of `red`, `blue`, `green`, `yellow`, `purple`, `orange`, `pink`, `cyan`; `model` is one of `sonnet`, `opus`, `haiku`, `fable`, `inherit` or a full model ID matching `^claude-[a-z0-9-]+$`; `permissionMode` is one of `default`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`, `plan`, `manual`; `isolation` is `worktree`; `memory` is one of `user`, `project`, `local`; any other key FAILs, since Claude Code ignores an unknown field silently and a typo disables the setting · Threshold: zero violations · Tier: official (unknown fields ignored); the key set is the Claude Code subagent field list.
- **LNT-60** · MUST · Files: (a) agent files; (b) agent files, `SKILL.md` and reference `*.md` · How: (a) both canonical blocks are present, found by their opening words; with the slot removed, each matches byte for byte; (b) every line that, after leading whitespace, starts with `- **Quote safely.**` equals the canonical quote-safely line byte for byte; the line itself is optional. The canonical texts and slot rules are in `references/agents/07-agent-safety.md`, Canonical blocks · Threshold: (a) both present and identical; (b) every such line identical.
- **LNT-61** · MUST · Files: agent bodies · How: grep for `AskUserQuestion`, `EnterPlanMode`, `ExitPlanMode`, `ScheduleWakeup`, `Workflow(` and for "ask the user" / "ask the human" / "ask the owner" / "confirm with the user" outside a quoted rule that forbids it · Threshold: zero.
- **LNT-62** · SHOULD · Files: agent files · How: frontmatter lacks `omitClaudeMd: true` · Threshold: zero, or a waiver saying why the agent needs the operating contract.
- **LNT-71** · INFO · Files: `SKILL.md` frontmatter and agent files · How: list every key of the artifact type's set (LNT-12 for skills, LNT-59 for agents) that is absent, as one INFO line `unset optional fields: <keys> (defaults apply)` · Threshold: none (reminder only) · Tier: ours (never forget an optional field exists).
- **LNT-72** · MUST · Files: a plugin's `SKILL.md` frontmatter (a `tech-` skill, a `standard-` skill under `plugins/standards/`, or a `procedure-` skill under `plugins/procedures/`) · How: the frontmatter sets `disable-model-invocation: true`; `references/development.md` exists; `metadata.label` is set and non-empty; a standard or procedure plugin sets no `metadata.base`; a tech plugin's `metadata.base`, when set, names a sibling plugin folder (or an installed `tech-<base>`) whose own frontmatter sets no `metadata.base` · Threshold: all · Tier: ours.
- **LNT-66** · MUST · Files: agent files · How: every key in REQUIRED is present with a non-empty value (YAML booleans count as values; only a missing key, null or "" is empty). The lint holds the list itself. REQUIRED: `name`, `description`, `tools`, `model`, `effort`, `maxTurns` (each an implicit default that is a real choice or can shift: tools inherit everything, model and effort defaults vary by model, no turn cap). Every other key in LNT-59's set may be absent (its documented default applies); the authors' field table is where each optional field is decided · Threshold: all six REQUIRED keys present · Tier: ours (each setting is visible and can be changed per agent).
- **LNT-67** · SHOULD · Files: agent files · How: description length (Terms) · Threshold: ≤ 400 · Tier: ours (near Anthropic's own agent descriptions; the total is LNT-65).
- **LNT-68** · SHOULD · Files: agent bodies · How: chars · Threshold: ≤ 6,000 · Tier: ours (near Anthropic's own long agent bodies; no official limit exists).
- **LNT-69** · SHOULD · Files: agent files · How: agent body chars plus, for each `skills:` entry that resolves (LNT-36), the chars of that skill's `SKILL.md` body, which a preload injects whole; name each unresolved entry in the message and skip it; `CLAUDE.md` is not counted (LNT-62 owns it) · Threshold: ≤ 12,000 · Tier: ours.
