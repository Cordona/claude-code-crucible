# Spec: crucible-events (and the install)

crucible-events writes and reads an effort's events, facts written once and never edited, and holds the small libraries other components source. The install pieces say what a Claude folder needs, and check whether it is there.

## The pieces

| Piece | Its one job |
|---|---|
| `scripts/event-write.sh` | The only writer: appends one event after its type's rule accepts it |
| `scripts/events-read.sh` | The one reader: prints an effort's events as a JSON array, or their paths |
| `scripts/lib/listing.sh` | `ls_events`: lists an effort's event files in seq order, optionally by type or family; `ls_is_type` and `ls_is_family`: the one rule for a type's name |
| `scripts/lib/lock.sh` | `lk_take` / `lk_release`: a folder lock, one writer at a time |
| `scripts/lib/sha256.sh` | `sh_sha256`: the sha256 of a file |
| `scripts/lib/atomic-write.sh` | `aw_write`: replaces a file whole or not at all |
| `hooks/pre-tool-use/deny-direct-event-write.sh` | Denies a Bash command that runs the writer directly |
| `hooks/matchers.json` | Declares that hook's matcher: `Bash` |
| `install/install-entries.sh` | Prints what an install needs |
| `install/install-check.sh` | Names what of that is missing |

The libraries are sourced, set no shell option, never refuse and never set a trap: the caller words its own refusal and releases the lock in its own EXIT trap.

## The event

Each event is `FOLDER/events/<seq>-<TYPE>.json`, seq padded to six digits:

`{type, seq, at, by, claude_session_id, iteration?, body}`

`by` is the writing script's name; `claude_session_id` comes from `CLAUDE_CODE_SESSION_ID` (null when unset); `iteration` is stamped only when given; `body` is the object from `--body-file`.

Each type has exactly one rule, `<component>/events/<TYPE>.jq`, in one of the components beside crucible-events. The writer finds it there and is never given it. No rule, or more than one, is refused, naming what it found. The rule gets `{event, prior}`, prior being every earlier event in seq order, and prints one plain reason per broken rule. Printing nothing accepts. A refusal writes nothing and exits 2 with the reasons joined on stderr.

Under the lock, seq is the count of existing events plus one, so it runs from 1 with no gaps. The event is built in a temp file, checked, set to mode 444, then moved into place. The lock is a `.lock` folder holding its owner's pid. A dead owner's lock is broken. A lock that stays held for about 5 seconds exits 6, with nothing written.

## Reading

`events-read.sh --effort FOLDER [--type TYPE] [--paths]` is the one reader. It prints the array (`[]` when empty), or with `--paths` the absolute file paths. A trailing `.*` takes a family (`effort.*`). Both scripts list through `lib/listing.sh`, the only place that knows the file name pattern, and check a type's name with its one rule: lowercase words of letters and hyphens, joined by dots.

## The guard

The PreToolUse hook on Bash denies a command that runs `event-write.sh`. That means a command word ending in `event-write.sh`, or one given to a shell (`sh`, `bash`, `dash`, `zsh`, `.`, `source`, including a `-c` string). Any leading `VAR=value` and the wrappers `env`, `exec`, `nice`, `nohup`, `time`, `command`, `sudo` and `timeout <n>` are looked through. It allows `--help` or `-h` alone, commands that only read or name the file, and the component scripts' own calls, which are not Bash tool calls.

It fails open: a command not mentioning the writer passes before any parsing, and a missing jq or unreadable input passes with a note on stderr. It sits on every Bash call, so a fault in it must never block the human.

Its stated scope is mistakes, not determined runs. A name the shell builds (expansion, variables, eval), a copy, or a pipe into a shell is not caught.

## The install

An install needs:
- every declared hook in settings;
- the space (`CRUCIBLE_HOME`, default `~/.crucible`) as an additional directory;
- an Edit deny rule on `efforts/*/events/**` (Claude Code applies an Edit rule to every tool that edits files);
- a link in the skills folder for every folder holding a `SKILL.md`;
- a link to the core `CLAUDE.md`;
- jq 1.6 or later.

Both scripts find this by scanning the `new-rewrite` tree, framework and domains. Hooks come from each `hooks/matchers.json`, which maps `<event folder>/<hook>.sh` to a matcher or null. The event comes from the folder name: `stop`, `pre-tool-use` or `post-tool-use`. An invalid `matchers.json` is refused. Skills come from each `SKILL.md`, named after their folder.

`install-entries.sh` prints the settings JSON to merge and the link commands (`--json`: one object). `install-check.sh` merges the settings files it reads (`--settings`, or the defaults) and prints one `missing:` line per gap (exit 1), or `installed` (exit 0). Neither edits settings or makes links: the human installs.

## Decided, and why

- One writer, one reader: each event's shape and listing live in one place, so callers cannot drift.
- The writer finds the rule itself: a caller cannot pass the wrong rule or skip one.
- Mode 444: "written once" holds by the file, not by habit.
- Seq under a lock: concurrent writers never collide or leave gaps.
- The guard fails open: a guard on every Bash call that can block the human costs more than the mistake it catches.
- Each component declares its own hooks: adding a hook touches only that component, never the install.
- The install only reads: the human's setup changes only on their go.

## Known limits

- "Beside" means two things today. The writer finds rules among the components that really sit beside crucible-events, so a domain component's rule is not found. effort-close finds `open-work.sh` among the skills folder's entries, so once installed it sees domain components. Nothing is wrong yet, because no domain component writes an event. The first one that does decides what "beside" means, once, for both; the recommendation is the installed skills folder, with crucible-events linked too.
- crucible-events has no `SKILL.md`, so it is never linked. Linked components reach it by real path, through `../../crucible-events` resolved from their real folder.
- The writer counts event files for seq, so a file added by hand would shift it. The Edit deny rule blocks that through the file-editing tools, but not through a shell write.
