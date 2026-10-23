# 00 · Sources and results

Purpose: every audit answer comes from a file on disk, found the same way by every auditor, and is written in one line another auditor can check.

The auditor reads another session's files after it ended. It never edits them, never runs a script of the audited flow that writes, and never asks the audited session anything. Each item checks a rule as the rewrite states it, so the auditor reads the cited rule, not the item's summary of it, whenever an answer turns on wording.

## Inputs

- **The audited session id** (a UUID), and the **config dir** it ran under (`CLAUDE_CONFIG_DIR`, default `~/.claude`).
- **The Crucible space** it used (`CRUCIBLE_HOME`, default `~/.crucible`).
- **The repository** it worked in, and the **checklist** this seat audits.

## Rule abbreviations

Paths are under `rewrite/`:

- **CL:** `framework/core/CLAUDE.md`.
- **FCD:** `domains/software-development/core/main-thread/flows/flow-code-development/SKILL.md`; **NPF:** its `references/no-plugin-fits.md`.
- **FAI:** `framework/core/main-thread/flows/flow-agent-initialization/SKILL.md`; **DPR:** its `references/dispatch-plan-rules.md`.
- **CHI:** `framework/core/main-thread/procedures/procedure-context/references/conflicting-human-instructions.md`; **HYC:** the same folder's `agent-context-rules.md`, the text the hook injects into every first message under `# Handling your context`.
- **PAG:** `framework/core/main-thread/procedures/procedure-approval-gate/SKILL.md`.
- **RT:** `domains/software-development/core/plugins/procedures/read-trackers/SKILL.md` (`procedure-read-trackers`).
- **CDA:** `domains/software-development/core/agents/code-developer/code-developer.md`; **SCDR:** its `skills/standard-code-development-report/SKILL.md`.
- **A plugin:** a standard is `domains/software-development/core/plugins/standards/<name>/SKILL.md`, a tech plugin `domains/software-development/plugins/tech/<name>/SKILL.md`, each with its `references/` (the shell gate is in `tech/shell/references/development.md`, SHD).

A script's `--help` is its full contract. When an item names a script's output, read the `--help` of the copy the audited session ran, under its config dir.

## Sources

Each checklist item names its source by these tags.

- **MAIN:** the main-thread transcript, `<config dir>/projects/<slug>/<session id>.jsonl`. The slug is the session's launch directory with every character that is not a letter or digit replaced by `-`. Find it rather than build it: `find <config dir>/projects -name '<session id>.jsonl'`. One JSON object per line:
  - `type: "user"` with `.message.content` a string: a human message, unless it starts `<task-notification>`. That one is Claude Code reporting a background agent, and its `<result>` holds the agent's reply, such as `REPORT: <path>`.
  - `type: "user"` with `.message.content` an array: tool results (`type: "tool_result"`, `tool_use_id`, `content`, and `is_error`, which may be absent; absent means not an error).
  - `type: "assistant"`: the main thread's text (`content[]` items with `type: "text"`) and its tool calls (`type: "tool_use"`, `id`, `name`, `input`).
  - Other line types (`attachment`, `api-request…`): metadata, such as the system prompt's environment block with the scratchpad path, and the tool list. Never cite a command from an `api-request-blob` line: Claude Code rewrites commands there (for example with a `cd <dir> &&` prefix). Cite the `assistant` line's `input`.
- **AGENT:** each subagent transcript, `<config dir>/projects/<slug>/<session id>/subagents/agent-<id>.jsonl`, with the same line shape. Its first `user` line is the first message the agent received. Beside it, `agent-<id>.meta.json` gives `agentType`, `description` and `toolUseId`. The `toolUseId` ties the agent to its MAIN Agent call.
- **SCRATCH:** the audited session's scratchpad, which holds the baseline and labels files. It is the folder the system prompt names as "Scratchpad directory", ending `/<session id>/scratchpad`. A subagent shares it.
- **SPACE:** the Crucible space. Each file is `<space>/<YYYY>/<MM>/<DD>/<kind>/<YYYYMMDDTHHMMSS>-<hex>-<label>.<ext>`, and each day folder has its own `index.jsonl`, one line per file: `id`, `kind`, `file`, `label`, `repo`, and so on. The kinds:
  - `context/*.json`:
    - `paths`: `[{path, why}]` or `null`;
    - `links`: `[{url, why}]` or `null`;
    - `notes`: `[text]`;
    - a long human text handed in as a text file is a second file, `context/*-text.json` (`{text}`), listed last in `paths`.
  - `gates/*-dispatch-plan.json`, the approved plan:
    - `v`, `agent`, `mode`, `tasks`, `context`;
    - `technology`: a label such as `Shell`, not a plugin name;
    - `loaded` and `not_loaded`: each `[{plugin, reason}]`; `loaded` includes the tech plugin;
    - `loaded_reason` and `replan`, when given.
  - `gates/*-no-plugin-fits.json`: `v`, `stack`, `files`, `tasks`.
  - `dispatches/*-dispatch.json`:
    - `id`, `started`, `agent`, `mode`;
    - `tech`: a plugin name;
    - `plugins`: `[{name, paths}]`;
    - `plan.path`, `plan.sha256`, `context.path`, `context.sha256`;
    - `task`, `repo_root`, `starting_points`, `report`.
  - `prompts/*-main-thread-prompt.md`: the direct path's message.
  - `reports/*-code-developer-report.json`, or `*-main-thread-report.json` on the direct path:
    - written by the agent (or the main thread on the direct path): `summary`, `toolchain`, `files`, `behavior`, `verification`, `deviations`, and when not empty `focus`, `decisions`, `noticed`, `open`, `blockers`;
    - stamped by `report.sh check --dispatch` on exit 0 or 1, never written by the agent: `tech`, `plugins`, `mode`, `dispatch`, `started`, `finished`.

  Find the run's files by what MAIN prints, never by date or name alone, since the space holds other sessions' files too:
  - **The context file:** the `CONTEXT_FILE:` line in `generate-agent-context.sh`'s result; after a step-3.4 rerun, the rerun's line.
  - **The dispatch:** the `DISPATCH:` line in `generate-agent-dispatch.sh`'s result. That file's `report`, `context.path` and `plan.path` name the rest. `plan.path` is the gate record. `PLAN_FILE:` names a cache file the gate removes, not the record.
  - **The direct path:** the `PROMPT:` and `REPORT:` lines in `prepare-agent-prompt.sh --direct`'s result.
  - **A no-plugin-fits gate record:** the day index line with `kind: "gates"`, `label: "no-plugin-fits"` and this session (read-only: `crucible.sh find --kind gates --session <id> --label no-plugin-fits`). Its `repo` is not the audited repository.
- **REPO:** `git -C <repo> status --porcelain` and `git -C <repo> diff`, plus the SCRATCH baseline file the main thread wrote before each dispatch. A 0-byte baseline is valid: the tree was clean. The tree is read today, so later edits show too; note any that the transcripts don't explain.

## Reading the transcripts

Read them with `jq`, never by eye over the raw file.

- **Calls in order:** `jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | "\(.name)\t\(.input|tostring|.[0:300])"' <file> | nl`. Cite a call as `MAIN call <n>` or `AGENT call <n>` by this numbering.
- **A call's result:** match its `id` to the `tool_use_id` of a later `tool_result`.
- **The human's messages:** `jq -r 'select(.type=="user" and (.message.content|type)=="string") | .message.content | select(startswith("<task-notification>")|not)' <MAIN>`.
- **Text:** cite the main thread's or the agent's text as `MAIN line <n>` or `AGENT line <n>`, the transcript's line number (`grep -n`, or `jq` with `input_line_number`). "A message" in an item means one `assistant` line's text.
- **A call's own echo:** a Bash call that ends with `echo "exit=$?"` adds that line to its result. It is not the script's stdout. When a call pipes the script (`… | head`), the echoed exit is the last command's, not the script's.

Parallel seats share one scratchpad, so write your own temp files only under a folder named for your seat, such as `<your scratchpad>/audit-<checklist>-<session id first 8>/`.

## Answers

Answer every item with one of four values:

- **PASS:** the fact on disk shows the item holds.
- **FAIL:** the fact on disk shows it does not hold.
- **N/A:** the run never reached what the item checks. Give the reason and its evidence, such as "no `prepare-agent-prompt.sh --direct` call".
- **UNDECIDABLE:** the source is missing or unreadable. Name the source and why; never guess.

Every answer carries one line of evidence: a call or line number, a `file:line`, a JSON field with its value, or a short quote. An answer with no evidence counts as UNDECIDABLE. A judgement item says so, and its evidence quotes both sides.

When an item FAILs because two rules of the rewrite disagree, say so in Notes with both rules' places. The fix then belongs in the rule, not the run.

## Results

One results file per audit seat, `.crucible/docs/audits/<YYYY-MM-DD>-<session id first 8>-<checklist>.md` in the repository holding this harness:

- **Header line:** `AUDIT <checklist> · SESSION <session id> · AUDITOR <agent or session> · DATE <YYYY-MM-DD>`.
- **One line per item:** `<ID> · PASS|FAIL|N/A|UNDECIDABLE — <evidence>`.
- **End lines:**
  - `COUNTS: pass <n> · fail <n> · n/a <n> · undecidable <n>`;
  - `Notes:` anything outside the items, such as a fact no item covers, or a rule conflict;
  - `Checklist feedback:` an item whose wording, source or decide rule did not fit the files, and why.

Then append one line per item to `.crucible/docs/audits/log.tsv`: `date`, `session`, `checklist`, `item`, `answer`, tab-separated. Counts across runs come from this log.
