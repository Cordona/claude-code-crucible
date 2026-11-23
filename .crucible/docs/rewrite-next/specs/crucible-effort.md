# Spec: crucible-effort

An effort gives tracked work a folder of its own and a record of what happened to it, outliving any session. This component starts, pauses, resumes, closes and shows efforts. Only the human changes an effort's state.

## The pieces

| Script | Its one job |
|---|---|
| `effort-start.sh --name NAME` | Makes the effort's folder and writes `effort.opened`; prints the folder |
| `effort-pause.sh --effort F --words T` | Writes `effort.paused` to an open effort |
| `effort-resume.sh --effort F --words T` | Writes `effort.resumed` to a paused or closed effort |
| `effort-close.sh --effort F --outcome done\|dropped --words T [--leave-open]` | Checks for open work, then writes `effort.closed` |
| `effort-status.sh --effort F` | Prints one effort's state in one line |
| `effort-list.sh [--all]` | Prints one tab-separated line per effort (folder, state, name, at), newest change first; closed ones only with `--all`, as `closed:<outcome>`; skips an effort whose events can't be read, names it on stderr and exits 3 |
| `effort-state.sh --effort F` | Prints one word, `open`, `paused` or `closed`, for other components to check |
| `lib/effort.sh` | Shared: the efforts folder, the folder check, the state summary, the call to the event writer |

Every script's `--help` is its contract. A script refuses with exit 2 and a plain reason; a writing script exits 6 when the events lock stayed held. Events are written by `crucible-events/scripts/internal/event-write.sh`, which applies this component's rule file for each type, `events/<type>.jq`.

## The events

| Type | Body | Field: reader |
|---|---|---|
| `effort.opened` | `name` | `name`: list, status |
| `effort.paused` | `words` | `words`: status |
| `effort.resumed` | `words` | `words`: status |
| `effort.closed` | `outcome`, `words`, optional `left_open` | `outcome`: list, status. `words`: status. `left_open`: status |

The envelope (`type`, `seq`, `at`, `by`, `claude_session_id`) comes from the writer. The newest effort event's type is the state, and its `at` is the time list and status show. Each rule refuses any other body field.

**States and moves:**

| From | Allowed moves |
|---|---|
| nothing | `effort.opened`, only as the first event |
| open (`opened` or `resumed` newest) | pause, close |
| paused | resume, close |
| closed | resume |

Every move after opening carries the human's words: the rules refuse `words` that are missing or blank. `outcome` must be `done` or `dropped`. `left_open`, when present, must be a non-empty list of one-line strings.

Other components read the state through `effort-state.sh`: grill, context and dynamic-flow scripts, and the dynamic-flow Stop hook.

## The folder

Efforts live in `${CRUCIBLE_HOME:-$HOME/.crucible}/efforts/`, one folder each, holding `events/`. The folder name is `<YYYYMMDDTHHMMSS>-<4 hex>-<slug>`: the start time in UTC, four random hex digits, then the name lowercased with every run of other characters turned into a dash (`effort` when nothing is left). The name is non-blank and up to 40 characters. Every script that takes `--effort` refuses a path that is not directly in the efforts folder, is a symlink, or has no `events/`.

## Open work at close

**The contract.** A component that can hold open work ships `scripts/internal/open-work.sh --effort FOLDER`. It reads only, prints one line per open thing and nothing when there is none. Today:
- dynamic-flow prints `flow <seq> "<goal>"` per flow agreed and not ended, oldest first;
- grill prints `grill <n> "<topic>"` per draft not yet ended, by number.

**The close.** `effort-close.sh` runs every `*/scripts/internal/open-work.sh` in the component folders beside its own. It names no component. Blank lines are dropped, and a check that exits non-zero adds `<component>/scripts/internal/open-work.sh: check failed`. If anything was found, the close is refused with the lines in the reason. A paused effort is checked the same way.

**Leaving work open.** With `--leave-open`, given only on the human's word, the close goes ahead and the script itself writes the found lines as `left_open`. Main never passes the list. With nothing found, no `left_open` is written. `effort-status.sh` appends `; left open: <lines>` to the closed line.

## Decided, and why

- **One small script per job, no hub:** each is callable alone, and its `--help` is the whole contract.
- **State is the newest effort event:** no state file to drift from the facts.
- **The human's words on every move:** the record shows why, in their terms.
- **Rules live in `events/<type>.jq`:** the writer enforces the allowed moves, so no script can skip them.
- **Open work is found, not named:** a new component joins by adding one file; effort never changes, and no component calls another by name.
- **The script writes `left_open`:** what was left open is what was actually found, not main's claim.
- **A failing check counts as open work:** a check that can't run must not let a close through silently.
- **The list skips a damaged effort, not the list:** each effort is its own log, so inside one effort the read stays all or nothing, and an effort that can't be read is left out, named on stderr with the reader's reason. The list goes on with the others and exits 3, so one bad file in an old effort never hides the rest from main.

## Known limits

- effort-close finds `open-work.sh` among the skills folder's entries, so a domain component's is seen once installed, where its link sits beside `crucible-effort`'s; in the repository's own tree it is not.
- `at` has one-second resolution: efforts changed in the same second have no order between them in the list.
- The open-work checks run before the state rule, so closing an already closed effort that still has open work is refused for the open work, not for being closed.
