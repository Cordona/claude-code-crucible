# Frontmatter fields — skills and agents

The full field sets Claude Code accepts, one row per field: what it does, the default when absent, and the allowed values. Authors take each field-table row's "what it does" from here; the owner decides each optional field from the same facts.

- **Lint:** `required` means the lint fails the artifact without the key (LNT-64 for skills, LNT-66 for agents); every other field is optional, and LNT-71 lists the unset ones on every run. Unknown keys fail LNT-12 (skills) and LNT-59 (agents): Claude Code ignores them silently, so a typo disables the setting.
- **Tags:** `(docs)` is Anthropic's docs or the Agent Skills spec; an item ID is the rulebook line that states the fact. `(inferred)` marks a reading the docs imply but do not state. "Not documented" means no source in this rulebook describes it; don't fill it from memory.
- **Versions:** a fact that holds only from a Claude Code version, or for one model, is pinned once in the Versions table at the end; a row marks it `(Versions)`.
- **Writing a default out:** whether that is valid is documented for no field (docs).
- **Booleans** take `true`/`false`/`yes`/`no`/`on`/`off`/`1`/`0` (LNT-12).

## Skill fields

| Field | Lint | What it does | Default when absent | Values |
|---|---|---|---|---|
| `name` | required | The skill's name; must equal its directory's deployed name (LNT-06). | — | `^[a-z0-9]+(-[a-z0-9]+)*$`, ≤ 64 chars, no `anthropic`/`claude` (docs) |
| `description` | required | What the skill does and when to use it; shown in the skill listing, whose budget drops descriptions on overflow (docs). | — | ≤ 1,024 chars (docs), no `<` `>` (LNT-10); ≤ 500 SHOULD (LNT-63) |
| `when_to_use` | optional | Trigger phrases and example requests, listed with the description. | Description alone is listed | String; description + this truncated at 1,536 chars in the listing (docs) |
| `argument-hint` | optional | Hint for the arguments a user-invocable skill takes (FM-07). | No hint | String |
| `arguments` | optional | Names the arguments, mapped to positions in order, usable as `$<name>` in the body (docs; LNT-21); a preload blanks them. | No named arguments | Space-separated string or YAML list (docs) |
| `disable-model-invocation` | optional | `true`: only a user can invoke it; agents can't preload it; its description is not in context (docs). | `false` (docs) | Boolean; `true` fails LNT-35 on any bound or house-prefixed skill, except a plugin, which (a `tech-` skill, or a `standard-` skill under `plugins/standards/`) is read by path only and sets it by design |
| `user-invocable` | optional | `false` hides the `/` entry when only Claude should invoke the skill; blocks neither the Skill tool nor preloading (docs). | `true` (docs) | Boolean |
| `allowed-tools` | optional | Pre-approves tools (no prompt) without restricting others; lasts until the next user message (SAFE-06, DET-09). | No pre-approvals | Tool names, `Bash(<glob>)`; bare `Bash` fails LNT-41 |
| `disallowed-tools` | optional | Restricts tools for the invoking turn only (DET-09). | Nothing restricted | Tool names |
| `model` | optional | Model for the invoking turn only; not saved to settings (docs, DET-09). | The active model | `/model` values or `inherit` (docs) |
| `effort` | optional | Effort level while the skill runs (docs). | The session's effort (inferred) | `low`, `medium`, `high`, `xhigh`, `max`; availability depends on the model (docs) |
| `context` | optional | `fork` runs the skill in a forked subagent context, which needs an explicit task and standalone instructions (docs, SUB-11). | Runs inline in the conversation | `fork` only (docs) |
| `agent` | optional | Which subagent type runs a `context: fork` skill (docs). | Not documented | An agent name |
| `background` | optional | Only with `context: fork`: runs the fork in the background (fewer tools; edits bypass `/rewind`) (docs, SUB-11). | `true` (docs; Versions) | Boolean |
| `hooks` | optional | Hooks that stay registered for the rest of the session; don't rely on them firing inside subagents (HK-01, HK-02). | No hooks | Hook config; `once` allowed only here (LNT-33) |
| `paths` | optional | Glob patterns that limit when the skill is activated (docs). | No path limit | Comma-separated string or YAML list (docs) |
| `shell` | optional | Shell used for the skill's `!` injected commands (docs). | `bash` (docs) | `bash`, `powershell` (docs) |
| `license` | optional | The skill's license name or a reference to a bundled license file; keep it short (spec). | None | String (spec) |
| `compatibility` | optional | Environment requirements, e.g. products, packages, network access (spec). | None | 1–500 chars (docs) |
| `metadata` | optional | Free-form extra properties; Claude Code drops a value that isn't a map (docs). | None | String→string map, no key reusing a field name (spec, LNT-13) |

## Agent fields

| Field | Lint | What it does | Default when absent | Values |
|---|---|---|---|---|
| `name` | required | The agent's name; a file with a bad name is skipped silently (ATOOL-01). | — | ≤ 256 chars, no `:` (docs); ours: `^[a-z0-9]+(-[a-z0-9]+)*$`, 3–50 chars, equals the file stem, unique (LNT-48, LNT-59) |
| `description` | required | When to delegate to the agent; all agent descriptions over 15,000 tokens trigger a startup warning (docs). | — | Non-empty; ≤ 400 SHOULD (LNT-67) |
| `tools` | required | The tools the agent holds; `Bash(pattern)` and `Agent(type)` restrict nothing (ATOOL-11, ATOOL-13). | Inherits every tool available to subagents, MCP tools included (docs) | Tool names; at least one must resolve (ATOOL-09) |
| `disallowedTools` | optional | Removes tools; an entry with a specifier removes the whole tool (ATOOL-14). | Nothing removed | Tool names |
| `model` | required | The agent's model; house rule pins a full ID (ATOOL-22). | Resolution order: per-invocation, then this field, then `CLAUDE_CODE_SUBAGENT_MODEL`, then the main session's model (docs) | `sonnet`, `opus`, `haiku`, `fable`, `inherit`, or a full model ID (docs) |
| `permissionMode` | optional | Permission mode; ignored when the main session runs in `bypassPermissions`, `acceptEdits` or `auto`; `bypassPermissions` is never honoured from here; plugin agents ignore it (ATOOL-17, ATOOL-05). | Inherits the main conversation's mode (docs) | `default`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`, `plan`, `manual` (= `default`) (docs) |
| `maxTurns` | required | Turn cap, a safety cap sized to the role (ATOOL-24). | Not documented (no cap assumed) | Integer |
| `skills` | optional | Preloads skills: each full body is injected; a missing one, or one with `disable-model-invocation: true`, is skipped with a debug warning (docs). | No preloads | Skill names, at most 32 (docs) |
| `mcpServers` | optional | MCP servers available to the agent; plugin agents ignore it (docs, ATOOL-05). | Not documented | Server names or inline definitions (docs) |
| `hooks` | optional | Hooks for this subagent's lifetime; `Stop` becomes `SubagentStop`; plugin agents ignore it (HK-02, ATOOL-05). | No hooks | Hook config (LNT-33) |
| `memory` | optional | Gives the agent a persistent memory store (loads the start of its `MEMORY.md`; size in Versions) and adds Read, Write and Edit (docs, ATOOL-18). | No memory | `user`, `project`, `local` (docs) |
| `background` | optional | Runs the agent in the background, with a reduced tool set (docs, ATOOL-21). | Not documented (foreground assumed) | `true` (only value documented) |
| `omitClaudeMd` | optional | `true`: `CLAUDE.md` is not loaded into the dispatch (managed-policy files still are); ignored when the agent is the main session (ALOAD-02; Versions). | `CLAUDE.md` loads (ALOAD-02) | `true`; whether `false` is accepted is not documented |
| `effort` | required | Effort level; overrides the session's effort (docs); the house model's default is in Versions. | The session's effort (inferred from docs) | `low`, `medium`, `high`, `xhigh`, `max` (docs) |
| `isolation` | optional | Runs the agent in a git worktree branched from the default branch, not the caller's HEAD (docs, ATOOL-15, ATOOL-16). | No worktree | `worktree` only (docs) |
| `color` | optional | Display colour for the agent in the UI (inferred; the docs list only the values). | Not documented | `red`, `blue`, `green`, `yellow`, `purple`, `orange`, `pink`, `cyan` (docs) |
| `initialPrompt` | optional | Text prepended to the agent's first user turn; plugin agents ignore it (docs, ATOOL-05). | None | String (docs) |
| `experimental` | optional | Experimental settings; documented key: `cacheTtl` (prompt-cache lifetime; Versions) (docs). | None | Map; `cacheTtl`: `5m` or `1h` (docs) |

## Versions

Every version- or model-dependent fact the rulebook relies on, in one place. Re-verify a row against the docs before relying on it after a Claude Code or model upgrade, and update its date.

| Fact | Value | Source | Last verified |
|---|---|---|---|
| House model, the full ID every agent pins (ATOOL-22) | `claude-opus-5-5` (Opus 5.5) | owner; the documented Opus 5.5 model ID | 2026-10-13 |
| House model's default effort (ATOOL-23) | `medium` | docs (model configuration) | 2026-10-13 |
| House model's context window, which sets LNT-42's budget | 1,000,000 tokens (its default 1M window) | docs, inferred: the 1M window is the default for Opus 4.7 and later (model configuration, context window) | 2026-10-13 |
| Skill `background` field | Claude Code 2.1.218+, default `true` | docs (skills) | 2026-10-13 |
| Agent `experimental.cacheTtl` | Claude Code 2.1.248+, values `5m`, `1h` | docs (subagents) | 2026-10-13 |
| Agent `omitClaudeMd` field (ALOAD-02) | Claude Code 2.1.271+ | docs (subagents) | 2026-10-13 |
| Read tool limit per call (ALOAD-10) | about 25,000 tokens | docs (tools) | not verified |
| Agent memory load (`memory`) | first 200 lines / 25 KB of `MEMORY.md` | docs (subagents) | not verified |
| `!` injected command timeout (DET-10) | 2 minutes | docs (skills) | not verified |
