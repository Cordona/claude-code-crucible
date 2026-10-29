---
name: crucible
description: The durable Crucible space outside every repo, where every file of an effort lives in that effort's folder, and `crucible.sh`, which hands out its paths, finds an item by ID, opens it for the human and prunes old efforts. Use when the main thread needs a durable file or the human asks to open or prune one. Writes only in the space. Not for throwaway files (the scratchpad) or an item's content (its writer's skill, e.g. `standard-code-development-report`).
user-invocable: false
---

# Shared: Crucible space

One folder, outside every repository, for the files Crucible keeps. Every file belongs to one effort and lives in that effort's folder, so an effort's work stays together and goes with it. The main thread holds only their absolute paths, so its context stays small, and the human opens any item by its ID.

## Rules

- **JSON only:** every item is one JSON object in its writer's shape; no Markdown is stored or rendered from an item, so the JSON stays the one source.
- **Drafts are the one exception:** the `drafts` kind holds every Markdown artifact the main thread writes inside an effort (a draft such as an issue, PR or MR body or a commit message, a brief, a summary, research), one `.md` file each. The main thread allocates one with `sh <crucible.sh> new --kind drafts --effort '<effort folder>' --label '<label>'`, writes the draft once into the empty file it prints (Read it first, as Write requires), and hands over that path; `prune` removes it with the effort.
- **An item's full view is its file's whole absolute path:** never a rendered copy, and opened only on the human's ask (The script).
- **`"v": 1` is in gate records only:** a report's or context file's shape is its validator's, which refuses any other key.
- **Every path is allocated with `crucible.sh new`, before the file is needed,** and only by scripts the main thread runs: `procedure-context`'s for the context, `flow-agent-initialization`'s for the plan records, the dispatch, baseline and report files and the hook's denial files, `procedure-approval-gate`'s question hook for gate records, `procedure-grill`'s `grill.sh` for grill files (the `grills` kind), `procedure-effort`'s `effort.sh` for state items (the `states` kind); the exceptions are a `drafts` file, which the main thread allocates itself, as the drafts rule above sets, and a fix round's report and baseline, which `flow-code-development` allocates with `crucible.sh new`. A gate before any effort, such as the effort offer, keeps its record in the session's gate folder, never in the space. An agent gets its `REPORT` path in its first message, or a fix round's in that round's message. Agents never run `crucible.sh` and write nothing in the space but that `REPORT` file.
- **Written once:** a file is not changed after the dispatch or gate that wrote it closes; a revision is a new file. Three exceptions: a report fixed on a rejection, before it passes its check; the stamps `report.sh check --dispatch` writes into a report when it passes; and a grill file, which `grill.sh` changes as each answer lands until the grill ends, and never after. A changed context is a new version, as `procedure-context` sets.
- **An effort's `metrics/` is `procedure-metrics`':** its `metrics.sh` names and rewrites the files there itself, outside `crucible.sh new`, the written-once rule and the prune module; `crucible.sh` neither allocates nor finds them.
- **Cache items expire:** gate records and denials expire as `crucible.sh --help` sets, and `crucible.sh new` removes expired ones; never hand one on as a lasting record.
- **Throwaway files stay in the session scratchpad:** labels files, temp files.
- **Never write a secret into an item;** a found secret is reported masked, by location.
- **Nothing outside the space is written or removed.**
- **The `settings.json` entry that allows the space is the human's,** as `flow-agent-initialization`'s install check sets.

## The script

`<crucible.sh>` is `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/crucible.sh"`. Its `--help` is the full contract. Run `sh <crucible.sh> --help` once, before its first use in a session, and not again in that session unless its contract is no longer in your context (after a compaction). Every other call runs only the command its step names.

- **The full view:** when the human asks for an artifact item's text, follow `standard-artifact-handoff`'s confirm step; any other item's text (a context version, a gate record) is shown as asked; otherwise its full view is the item's whole absolute path, from `sh <crucible.sh> path <ID>`.
- **Open only when the human asks to open it:** `sh <crucible.sh> open <ID>`, never with a terminal editor as `--editor`; it opens the item's file itself, so relay its one stdout line as printed.
- **Prune only on the human's ask, dry run first:** `sh <crucible.sh> prune --older-than <N>d`, and show its lines; add `--apply` only on their go, since it removes whole effort folders.

## The prune module

`scripts/lib/prune.jq` holds `prune`, the clean-up every script-written JSON record outside `metrics/` passes through before it is written, so a reader treats a missing key as empty.

- **Input:** any JSON value. **Output:** the value with every object key whose value is null, `[]` or `{}` dropped, children pruned first; array items pruned, never dropped; `false`, `0` and `""` kept.
- **Loaded by every script that writes such a record,** just before writing: jq with `-L "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/lib"` and `include "prune";` ahead of any `def`, since jq takes module directives only at a program's start.
- **Two exceptions among them, the dispatch baseline and a fix round's (`report.sh baseline`):** each keeps `entries: []`, since an empty list means a clean tree.
