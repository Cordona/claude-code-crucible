# Spec: the completeness review's fixes before the live run (A2, A3, B1, B2, C1)

Source: `reviews/core-completeness-review.md`. A1 (the core `CLAUDE.md`) is done. Each piece below needs the owner's go before it's built.

## A2. Install: the expected entries, and a read-only check

**Home:** `new-rewrite/framework/core/install/`

| Piece | One job |
|---|---|
| each component's `hooks/matchers.json` | Next to its hooks: the matcher for each hook script, such as `{"pre-tool-use/check-question-shape.sh": "AskUserQuestion"}`. The event is already in the folder name |
| `install-entries.sh` | Prints what an install needs: the settings entries with absolute paths, and the link commands for the skills and for `CLAUDE.md`, as lines for the human to run |
| `install-check.sh [--settings FILE]...` | Compares what is installed with what is needed, and prints one plain line per thing missing |

Both scripts find what is needed by scanning `new-rewrite/` (framework and domains): hooks through each `hooks/matchers.json`, and skills through each `SKILL.md`. A component that adds a hook edits only its own `matchers.json`; core's install changes nothing (V11, V15).

**What an install needs:**
- **Every hook** the scan finds: six today, counting C1's.
- **Every skill folder** linked into `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/<folder name>`.
- **The core `CLAUDE.md`,** linked as `${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md` or as the project's `./CLAUDE.md`. Without it, an install with every hook would pass the check and still run without the rules.
- **jq 1.6 or later on PATH.** Every hook depends on it.
- **The space allowed as a directory:** `${CRUCIBLE_HOME:-~/.crucible}` in `permissions.additionalDirectories`.
- **C1's deny rules:** `Edit` and `Write` on the space's `efforts/*/events/`.

**The check:**
- Reads the settings files given, or by default the user file plus the project's `.claude/settings.json` and `.claude/settings.local.json` when present. It takes the entries of all of them together, as Claude Code merges them.
- A hook counts as present when an entry for its event and matcher runs a command naming that script's absolute path, and the file exists.
- A link counts when it points at the framework's file or folder.
- **Read-only:** it never edits settings or links (V13).
- **Exit:** 0 when everything is in place; 1 when something is missing, one line each; 2 for a usage error.

## A3. The gate's clause for hooks that didn't run

This adds one sentence to `crucible-gate/SKILL.md`. If a turn ended after a card and no hook told you to ask, the gate's hooks aren't running: tell the human, and suggest the install check in the framework's `install/` folder. That gives main a word to say where the gate would otherwise hang in silence. The prose names the folder, not the script.

## B1. Events are read-only

`event-write.sh` makes the temp file mode 444 before the `mv`. Nothing in the framework edits an event: the writer is the only one, and it writes each event once. "Written once, never edited" (V4, V10) then holds by the file mode, not by habit. The evidence runs are re-run to show that nothing broke, and one case shows the mode.

## B2. `effort-close.sh` refuses while open work remains

**A shared contract, owned by each component.** A component that can hold open work ships `scripts/open-work.sh --effort FOLDER`. It prints one line per open thing, such as `flow 12 "Prune nightly"` or `grill 2 "second grill"`, and nothing when there is none.
- **Flow:** open flows, read from its own events.
- **Grill:** open drafts.
- **The future:** a later component, such as seats or a review, joins by adding the one file. Effort changes nothing.

**`effort-close.sh`** runs every `*/scripts/open-work.sh` it finds among the component folders beside its own. Effort names no component, and nothing in effort calls grill or flow by name, so the two never call each other.
- **Any line printed:** refused, naming the lines.
- **A check that fails** (a non-zero exit): refused, naming the script.
- **`--leave-open`,** given only on the human's words, which `--words` carries. The script closes anyway, and itself writes what it found into the body: `left_open: [<the lines>]`, plus `"<script>: check failed"` for a check that couldn't be made. Main never passes the list, so it can't claim loosely. With nothing open, nothing is recorded.
- **The rule** (`effort.closed.jq`) checks only `left_open`'s shape: an array of one-line strings.
- **The reader:** `effort-status.sh` adds `left open: <lines>` to the closed line.
- **Paused efforts:** a paused effort is checked the same way.

## C1. A guard on the event writer

- **Home:** `crucible-events/hooks/pre-tool-use/deny-direct-event-write.sh`, a PreToolUse hook on Bash.
- **What it denies:** a command that runs `event-write.sh` directly. A name ending in `event-write.sh` after `sh`, `bash`, `./`, an absolute path or `exec` counts as a run.
- **What it allows:** reading or naming the file (`cat`, `sed`, `grep`, `head`, `less`, `ls`, `command -v`), and a run with only `--help` or `-h`. A component's own script that calls the writer is not a Bash tool call, so it is untouched.
- **The deny reason:** "events are written only by their component's scripts; run the script for what you want to record".
- **The scope, stated in its `--help`:** it guards against a run by mistake. It doesn't chase names the shell builds or indirection, the same limit the old guard accepted.
- **Fails open:** it sits on every Bash call, so a fault in it must never block main. A command that doesn't mention `event-write.sh` is allowed at once, before anything is parsed. If jq is missing or the input can't be read, the call goes through with a note on stderr.
- **Plus the `Edit` and `Write` deny rules on `events/`,** listed by A2.

## Evidence

- **A2:** a run against a scratch settings file:
  - empty: everything missing;
  - partial: the rest missing;
  - complete, from `install-entries.sh`'s own output: exit 0;
  - everything but `CLAUDE.md`, and everything but jq: each named as missing.
  - Plus a broken link, and a hook path that doesn't exist.
- **B1:** the mode of a written event; the next event written after a read-only one, with the lock unaffected; and every earlier evidence run re-run with only hashes, ids and times changing.
- **B2:**
  - close with an open flow: refused, naming it;
  - close with an open grill: refused;
  - close with both: refused, naming both;
  - `--leave-open`: closed, with `left_open` in the body and in the status line;
  - a component whose open-work check fails: refused; then `--leave-open` records it;
  - `--leave-open` with nothing open: closed, with nothing recorded;
  - after the flow and the grill end: closed normally.
- **C1:** the hook fed tool-input JSON:
  - a direct run by `sh`, by `bash`, by an absolute path and by `./`: denied;
  - `--help`, `cat`, `grep` and `sed -n`: allowed;
  - a component script's own run, such as `sh effort-pause.sh`: allowed;
  - another tool: allowed;
  - a command that only mentions the name inside a string: allowed;
  - bad JSON, and jq missing: allowed, with a note.

## Decided (Fable's review, 2026-11-21)

- **A3 and B1:** go as designed.
- **A2:** each component declares its own hook matchers, and the scripts find them by scanning. The install also covers the core `CLAUDE.md`, jq, and the link commands.
- **B2:** the shared `open-work.sh` contract, instead of effort naming flow and grill. `left_open` is written by the script, not passed by main.
- **C1:** fails open. A hook fault never blocks the human.
