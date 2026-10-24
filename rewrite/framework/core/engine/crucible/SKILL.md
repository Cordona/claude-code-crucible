---
name: crucible
description: The durable Crucible space outside every repo, where every file of an effort lives in that effort's folder, and `crucible.sh`, which hands out its paths, finds an item by ID, opens it for the human and prunes old efforts. Use when the main thread needs a durable file or the human asks to open or prune one. Writes only in the space and `open`'s temp folder. Not for throwaway files (the scratchpad) or an item's content (its writer's skill, e.g. `standard-code-development-report`).
user-invocable: false
---

# Shared: Crucible space

One folder, outside every repository, for the files Crucible keeps. Every file belongs to one effort and lives in that effort's folder, so an effort's work stays together and goes with it. The main thread holds only their absolute paths, so its context stays small, and the human opens any item by its ID.

## Rules

- **JSON, but prompts:** every item is one JSON object in its writer's shape, except a prompt, the Markdown message the main thread reads on the direct path; other Markdown is rendered on demand by `open`, never stored, so the JSON stays the one source.
- **`"v": 1` is in gate records only:** a report's or context file's shape is its validator's, which refuses any other key.
- **Every path is allocated with `crucible.sh new`, before the file is needed,** and only by scripts the main thread runs: `procedure-context`'s for the context, `flow-agent-initialization`'s for the dispatch, baseline, report and prompt files, `procedure-approval-gate`'s question hook for gate records. A gate before any effort, such as the effort offer, keeps its record in the session's gate folder, never in the space. An agent gets its `REPORT` path in its first message. Agents never run `crucible.sh` and write nothing in the space but that `REPORT` file.
- **Written once:** a file is not changed after the dispatch or gate that wrote it closes; a revision is a new file. Two exceptions: a report fixed on a rejection, before it passes its check, and the stamps `report.sh check --dispatch` writes into a report when it passes. A changed context is a new version, as `procedure-context` sets.
- **Cache items expire:** gate records and prompts expire as `crucible.sh --help` sets, and `crucible.sh new` removes expired ones; never hand one on as a lasting record.
- **Throwaway files stay in the session scratchpad:** labels files, temp files.
- **Never write a secret into an item;** a found secret is reported masked, by location.
- **Nothing outside the space is written or removed,** except `open`'s temp folder, as its `--help` sets.
- **The `settings.json` entry that allows the space is the human's,** as `flow-agent-initialization`'s install check sets.

## The script

`<crucible.sh>` is `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/crucible.sh"`. Its `--help` is the full contract. Run `sh <crucible.sh> --help` once, before its first use in a session, and not again in that session unless its contract is no longer in your context (after a compaction). Every other call runs only the command its step names.

- **Open on the human's ask:** `sh <crucible.sh> open <ID>`, never with a terminal editor as `--editor`; show its one line, or give the path.
- **Prune only on the human's ask, dry run first:** `sh <crucible.sh> prune --older-than <N>d`, and show its lines; add `--apply` only on their go, since it removes whole effort folders.
