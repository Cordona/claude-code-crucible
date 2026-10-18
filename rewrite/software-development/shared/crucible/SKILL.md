---
name: crucible
description: The durable Crucible space outside every repo, where each context file, gate record and agent report is one JSON file, and `crucible.sh`, which hands out its paths, finds an item by ID, opens it for the human and prunes old days. Use when the main thread needs a durable file or the human asks to open or prune one. Writes only inside the space; needs jq 1.6+. Not for throwaway files (the scratchpad) or an item's content (its writer's skill, e.g. `standard-code-development-report`).
user-invocable: false
---

# Shared: Crucible space

One folder, outside every repository, for the files Crucible keeps. The main thread holds only their absolute paths, so its context stays small, and the human opens any item by its ID.

## Rules

- **JSON only:** each item is one JSON object in its writer's shape; Markdown is rendered on demand by `open`, never stored, so the JSON stays the one source.
- **`"v": 1` is in index lines and gate records only:** a report's or context file's shape is its validator's, which refuses any other key.
- **The main thread allocates every path** with `crucible.sh new`, before the file is needed, and hands it to the agent in its brief. Agents never run `crucible.sh` (a reviewer has no Bash) and write nothing in the space but the `REPORT` file their brief names.
- **Written once:** a file is not changed after the dispatch or gate that wrote it closes; a revision is a new file. Two exceptions: the context file, which the main thread may revise until its last dispatch, each revision approved again at the gate through its digest; and a report fixed on a rejection, before it passes its check.
- **Throwaway files stay in the session scratchpad:** baselines, labels files, temp files.
- **Never write a secret into an item;** a found secret is reported masked, by location.
- **Never edit `settings.json`:** `procedure-agent-initialization`'s install check prints the entry that allows the space, and the human adds it.

## The space

`${CRUCIBLE_HOME:-$HOME/.crucible}`, an absolute path; `CRUCIBLE_HOME` points a test or sandbox elsewhere. Folders and names use local time:

```
<space>/YYYY/MM/DD/index.jsonl                                  one line per item
<space>/YYYY/MM/DD/<kind>/<YYYYMMDDTHHMMSS>-<hex>-<label>.json
```

- **Kinds:** `context`, `gates`, `reports`; any other is refused.
- **ID:** `<YYYYMMDDTHHMMSS>-<hex>`, read from the file name. Its 4 hex alone find the newest day holding them; an older item with the same hex needs its full ID.
- **Private:** folders 700, files 600; a symbolic link in the layout is refused.

## The script

`sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/crucible.sh"`, POSIX sh; its `--help` is the full contract.

| Command | Does | Prints |
|---|---|---|
| `new --kind <kind> --label <label> [--repo <git root>] [--session <id>]` | creates an empty file, never overwriting one, and its index line; label `a-z0-9-`, at most 60 characters | the file's absolute path |
| `path <id>` | finds the item through the index | its absolute path |
| `open <id> [--format md\|html] [--editor <cmd>]` | renders the item to a temp folder outside the space (a report through `report.sh render --full`) and opens it with the OS opener (`open` on macOS, `xdg-open` on Linux), or with `--editor <cmd>`, never a terminal editor, which would hang the Bash tool; `--format html` is not available yet | one line, `opened <file>` |
| `prune --older-than <N>d [--apply]` | lists the day folders older than N days; removes them only with `--apply`, never today, yesterday or a day with a file modified in the last 24 hours | one `would remove`, `removed` or `kept <folder> (<reason>)` line each, then a count |

- **Open on the human's ask,** and show its one line; or give the path.
- **Prune only on the human's ask:** run it without `--apply` and show the list; `--apply` on their go.
- **Exits:** 0 ok; 1 no item has that ID, several in its newest day share the hex (use the full ID), or the indexed file is gone; 2 usage, `--format html` included; 4 the space can't be created or written, a folder in it is a symbolic link, or `new` waited 10 seconds for a busy index lock; 5 install fault, named on stderr.
- **Dependencies:** POSIX sh and jq 1.6+ (macOS: `brew install jq`; Linux: the distro's `jq` package); the base-system tools are the ones `crucible.sh --help` lists.
