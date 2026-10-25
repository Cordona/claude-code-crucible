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
- **FCD:** `domains/software-development/core/main-thread/flows/flow-code-development/SKILL.md`.
- **FAI:** `framework/core/main-thread/flows/flow-agent-initialization/SKILL.md`; **DPR:** its `references/dispatch-plan-rules.md`.
- **PC:** `framework/core/main-thread/procedures/procedure-context/SKILL.md`; **CHI:** its `references/conflicting-human-instructions.md`; **HYC:** its `references/agent-context-rules.md`, the text the hook injects into every first message under `# Handling your context`.
- **PAG:** `framework/core/main-thread/procedures/procedure-approval-gate/SKILL.md`.
- **RT:** `domains/software-development/core/plugins/procedures/read-trackers/SKILL.md` (`procedure-read-trackers`).
- **CDA:** `domains/software-development/core/agents/code-developer/code-developer.md`; **SCDR:** its `skills/standard-code-development-report/SKILL.md`.
- **A plugin:** a standard is `domains/software-development/core/plugins/standards/<name>/SKILL.md`, a language plugin `domains/software-development/plugins/tech/languages/<name>/SKILL.md`, a framework plugin `domains/software-development/plugins/tech/frameworks/<name>/SKILL.md`, each with its `references/` (the shell gate is in `tech/languages/shell/references/development.md`, SHD).

A script's `--help` is its full contract. When an item names a script's output, read the `--help` of the copy the audited session ran, under its config dir.

## Sources

Each checklist item names its source by these tags.

- **MAIN:** the main-thread transcript, `<config dir>/projects/<slug>/<session id>.jsonl`. The slug is the session's launch directory with every character that is not a letter or digit replaced by `-`. Find it rather than build it: `find <config dir>/projects -name '<session id>.jsonl'`. One JSON object per line:
  - `type: "user"` with `.message.content` a string: a human message, unless it starts `<task-notification>`. That one is Claude Code reporting a background agent, and its `<result>` holds the agent's reply, such as `REPORT: <path>`.
  - `type: "user"` with `.message.content` an array: tool results (`type: "tool_result"`, `tool_use_id`, `content`, and `is_error`, which may be absent; absent means not an error).
  - `type: "assistant"`: the main thread's text (`content[]` items with `type: "text"`) and its tool calls (`type: "tool_use"`, `id`, `name`, `input`).
  - Other line types (`attachment`, `api-request…`): metadata, such as the system prompt's environment block with the scratchpad path, and the tool list. Never cite a command from an `api-request-blob` line: Claude Code rewrites commands there (for example with a `cd <dir> &&` prefix). Cite the `assistant` line's `input`.
- **AGENT:** each subagent transcript, `<config dir>/projects/<slug>/<session id>/subagents/agent-<id>.jsonl`, with the same line shape. Its first `user` line is the first message the agent received. Beside it, `agent-<id>.meta.json` gives `agentType`, `description` and `toolUseId`. The `toolUseId` ties the agent to its MAIN Agent call.
- **SCRATCH:** the audited session's scratchpad, which holds the labels files. It is the folder the system prompt names as "Scratchpad directory", ending `/<session id>/scratchpad`. A subagent shares it.
- **SPACE:** the Crucible space. Each file is `<root>/efforts/<effort>/<kind>/<ID>-<label>.<ext>`, `<ID>` being `<YYYYMMDDTHHMMSS>-<hex>`, as `crucible.sh --help`'s Layout sets, which names no index file. The kinds:
  - `context/*.json`:
    - `paths`: `[{path, why}]` or `null`;
    - `links`: `[{url, why}]` or `null`;
    - `notes`: `[text]`;
    - a long human text handed in as a text file is a second file, `context/*-text.json` (`{text}`), listed last in `paths`.
  - `plans/*-dispatch-plan.json`, the plan as generated (the `PLAN_RECORD:` file), and `cache/gates/*-dispatch-plan.json`, the gate record of the plan shown (`v` and the same keys; it expires):
    - `agent`, `mode`, `tasks`, `context`;
    - `plugins.load`: `language`, one `{plugin, reason}`; `frameworks`, `standards` and `procedures`, each `[{plugin, reason}]`;
    - `plugins.skip`: `standards` and `procedures`, each `[{plugin, reason}]`; a language or framework is never skipped, only left out;
    - `plugins.load_reason`, only when nothing is loaded, and `replan`, when given.
  - `dispatches/*-dispatch.json`:
    - `id`, `started`, `agent`, `mode`, `task`, `repo_root`, `entry_points`;
    - `plugins`: `language`, one `{name, paths}`; `frameworks`, `standards` and `procedures`, each `[{name, paths}]`;
    - `context.path`, `context.sha256`, `plan.sha256`, `report`, `baseline`.
  - `baselines/*-baseline.json`, written by the Agent hook (`prepare-agent-prompt.sh`) at the dispatch's first call and kept on a resend: `repo_root`, `taken`, and `entries`, one `git status --porcelain=v1 -z --no-renames` entry each.
  - `reports/development/*-code-developer-report.json`:
    - written by the agent: `summary`, `toolchain`, `files`, `behavior`, `verification`, `deviations`, and when not empty `focus`, `decisions`, `noticed`, `open`, `blockers`;
    - stamped by `report.sh check --dispatch` on exit 0 or 1, never written by the agent: `dispatch`, `started`, `finished`, `mode`, `plugins` (the dispatch's `plugins`, names only).

  In the plan, dispatch and report files, a key holding nothing (null, `[]` or `{}`) is left out: read a missing key as empty. A dispatch or report that loads nothing has no `plugins` key.

  Find the run's files by what MAIN prints, never by date or name alone, since the space holds other sessions' files too:
  - **The context file:** the `CONTEXT_FILE:` line in `context.sh`'s result (`new`, `extend`, or `latest` on Resume); after an extension (PC step 5), the extension's line. A dispatch's `context.path` names the version it pinned.
  - **The dispatch:** the `DISPATCH:` line in `generate-agent-dispatch.sh`'s result. That file's `report`, `baseline` and `context.path` name the rest.
  - **The approved plan:** the `PLAN_RECORD:` line of the `generate-dispatch-plan.sh` result whose `PLAN_SHA256:` equals the dispatch's `plan.sha256`. `PLAN_FILE:` names the gate's session plan file, which the gate removes, not the record.
- **REPO:** `git -C <repo> status --porcelain` and `git -C <repo> diff`, plus the SPACE baseline file each dispatch's `baseline` names. An empty `entries` is valid: the tree was clean. The tree is read today, so later edits show too; note any that the transcripts don't explain.

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
- **N/A:** the run never reached what the item checks. Give the reason and its evidence, such as "MAIN has no compaction".
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
