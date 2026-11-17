---
name: human-view
description: "How scripts show the human a card: `show.sh` prints each card from its skill's template and records it as owed; `show-stop-hook.sh`, a Stop hook, sends main back until the card is in its final message. Also the shared modules `view.jq`, `paths.jq`, `title.jq`, `gate.jq`, `line.jq`. Use when a script prints a card. Never loaded by the model; main runs only `show.sh line` and `render`. Writes only owed records and a `view.missed` event; needs jq 1.6+. Not for input checks or a card's content."
user-invocable: false
---

# Library: human-view

How a card reaches the human: one script prints it, one Stop hook checks it was shown. Its jq modules only turn a value into display text.

## Scripts

In `scripts/`; each one's `--help` is its full contract.

- **`show.sh`:** the only way a script prints a card: it renders the skill's template (`views/<name>.jq`, or a line in `views/lines.jq`), prints it, and records it as owed this session. Its `render` command renders a gate's template and records nothing, for a gate renderer or for main when no data must be built: `open-gate.sh` shows and records the gate.
- **`show-stop-hook.sh`** (the Stop hook; Claude Code runs it): sends main back while an owed card is missing from its final message (a gate must end it, with only owed cards above it), at most twice; then lets the stop through and writes `view.missed`.
- **A question that follows a card is a gate** (`procedure-approval-gate`): the card goes above the gate in main's final message, and the gate's question waits until both are shown. The hooks check only their own input.
- **`lib/`:** the owed record's one copy of its paths, checks and limits and the shown check, and `render.sh`, the show.sh calls a script prints a gate, a card or a line through (`open-gate.sh`'s gates included), with one exit mapping, and `hv_check_printer`, the one check that show.sh and the script's templates are in place.
- **A skill's shared defs:** `show.sh` also loads modules from the card's `views/` folder, so a skill's templates share a def through one module there (`include "common";` reads `views/common.jq`); human-view's modules win a name clash.

## Rules

- **Every template goes through human-view:** a view's first line, sections, lists and Data section come from `view.jq`, and every path it prints from `view.jq` or `paths.jq`, never from a copy inside the template.
- Use `short_path` and `code_span` only for a path cited for recognition inside a line of text, never for a path handed over.
- **Helpers only:** a module formats values for display and checks nothing, `line.jq`'s `field` aside; validating input stays in the script that reads it.
- **It grows by module:** a display function a second template needs becomes a def here, listed under Modules, and the templates' own copies are deleted.

## Layout rules

Every view a template lays out for the human follows these; the def named after a rule builds it.

1. **First line:** a bold title, then optionally ` · ` and a count, or in a status view a state word. The title's words or the state word carry the meaning (such as `Blocked`); no icon anywhere in the view (`status_line`).
2. **Headings are plain bold text, no icon:** a section's `**Name**` on its own line, or `**Name:** value` when it holds one item (`section`).
3. **Lists:** one item is a plain line with no mark; two or more are numbered (`1.`), never bullets (`section`). One exception: an offer's or a hint's list, placed right under the line it completes, is bulleted (`bullet_section`, or `bullet_list` under a line of its own). A gate's list the human answers by number stays numbered even with one item (`numbered_section`).
4. **Field lines** (Created, Modified, Deleted) are plain lines ending in two spaces (a hard break), a zero count left out (`field_lines`).
5. **A path the human may open** is whole and absolute: never `~`, never cut in the middle (`path_text`).
6. **Data last:** a view built from JSON in the Crucible space ends with that JSON's paths: one as `**Data · <Kind>:** <path>`, two or more as `**Data**` and a numbered `<Kind>: <path>` list (`data_section`). A view with no JSON behind it has no Data section. Three exceptions: a view repeated through one run (such as a grill round) shows its Data only on its last view, or in the view that follows the run (what-next after a grill); a one-line view carries its path inline, after its title; a status view ends with its folder's bare path.
7. **No constants:** a value that is the same on every view (a single agent, a single mode) is not shown, until a second value exists.
8. **Gates keep their `_Crucible gate_` marker,** from `gate.jq`, which `open-gate.sh` adds; a template never prints it.
9. **Every card is a template:** its layout lives only in its skill's `views/` folder, and only `show.sh` prints it.

Blocks of a view are joined by one blank line (`blocks`).

## Loading a module

A template includes each module it uses by name, without `.jq`, before any `def` (jq takes module directives only at the start of a program): `include "view";`, or `include "common";` for its skill's own `views/common.jq`. `show.sh` passes jq the folders: human-view's first, then the card's `views/`. Needs jq 1.6+.

## Modules

| Module | Holds |
|---|---|
| `view.jq` | A view's layout, as the Layout rules set: its status line, sections, numbered and bullet lists, plain lines, field lines, Data section and whole paths |
| `paths.jq` | Path and link display for a path cited for recognition: the shortening, the `~` form for the home folder, the middle cut and the 80-character cap; and `link_span`, a whole path in backticks |
| `gate.jq` | The gate marker `_Crucible gate_`, and the gate text without trailing blank lines |
| `line.jq` | `field($name)`, the one way a template reads a field it needs: missing, null or `""`, `show.sh` refuses the card, exit 2, naming the line or template and the field; `sentence`, a field's text with `.` added unless it already ends with one, for a line that ends a sentence on a field; and `not_installed($what; $fix)` (`$fix` defaulting to `skills_install`, installing under the skills folder), the one wording of a line saying something is not installed, ending `then ask me again.`; and `skill_not_installed`, that line for the skill in its input's `skill` field, which a skill shows with its own `--views` when its `views/lines.jq` includes `line` |
| `title.jq` | The one place a build agent, test agent or reviewer title is built from a language label and framework labels, and a seat's name for the human from its seat name; the caller passes the role word and never adds it itself |

`view.jq`'s public defs. A def returning `""` means nothing to show, and `blocks` drops it. Only `shown` and `one_line` clean control characters, so a value taken from outside goes through one of them first.

| Def | Input | Output |
|---|---|---|
| `shown` | text | each control character and each line or paragraph separator (U+2028, U+2029) as `?` |
| `one_line` | text | each run of control characters and line or paragraph separators as one space |
| `counted($one; $many)` | a count | `<count> <one>` for 1, else `<count> <many>` |
| `numbered_list` | array of strings | one `N. item` line per item, joined by newlines |
| `bullet_list` | array of strings | one `* item` line per item, joined by newlines |
| `plain_line` | one line of text | the line with a leading Markdown block mark (a heading, a quote, a rule, a list item or a code fence) backslash-escaped, so it shows as plain text at the start of a line or list item; inline Markdown stays as written |
| `path_text` | absolute path | the path whole, as plain text: no `~`, no cut, no backticks |
| `status_line($status; $title; $tail)`, `status_line($status; $title)` | ignored; `$status` (`decision`, `done`, `attention` or `blocked`) prints nothing | `**<title>**`, then ` · <tail>` when `$tail` is neither `""` nor null |
| `section($name; $plural; $items)`, `section($name; $items)` | ignored | `""` for no items; `**<name>:** <item>` for one; `**<plural>**` and a numbered list for two or more (`$plural` defaults to `$name`) |
| `bullet_section($name; $items)` | ignored | `""` for no items; else `**<name>:**` and a bullet list under it (Layout rule 3's offer or hint list) |
| `numbered_section($name; $items)` | ignored | `""` for no items; else `**<name>**` and a numbered list, even for one item |
| `field_lines($pairs)` | ignored; `$pairs` an array of `[name, count]` or `[name, count, tail]` | one `<name>: <count>` line per non-zero count, with ` · <tail>` when given, joined by a two-space hard break; `""` when every count is zero |
| `data_section($pairs)` | ignored; `$pairs` an array of `[kind, path]` | `""` for no pairs; `**Data · <kind>:** <path>` for one; `**Data**` and a numbered `<kind>: <path>` list for two or more; paths through `path_text` |
| `blocks` | array of blocks, `""` or null for one with nothing to show | the non-empty blocks joined by one blank line |

`paths.jq`'s public defs. Each reads a string and returns a string unless its row says otherwise. None cleans control characters, so clean a value before passing it:

| Def | Input | Output |
|---|---|---|
| `span_cap` | none | 80, the most characters a code span holds |
| `cut_head` | none | 30, the characters a middle cut keeps before its `…` |
| `middle_cut($tail)` | string | its first `span_cap - 1 - $tail` characters, `…`, then its last `$tail` |
| `capped` | string | the input, or when over `span_cap`, its first `cut_head` characters, `…` and its last 49 |
| `code_span` | string | the input capped and in backticks, each backtick in it shown as `'` |
| `link_span` | string | the input whole in backticks, never `~`-shortened or cut, each backtick in it shown as `'`: for a path shown as a link |
| `base_name` | string | the text after the last `/` |
| `home_form($home)` | string | the input with a leading `$home` folder written as `~`; unchanged when `$home` is empty or isn't its start |
| `short_path($home)` | string | `home_form`, then capped, with the basename kept whole when it is at most `span_cap - 2` characters |

`title.jq`'s public defs:

| Def | Input | Output |
|---|---|---|
| `joined_labels` | array of labels | `A`, `A and B`, or `A, B and C` for three or more, in the given order |
| `title($role)` | `{language: label, frameworks: [labels]}`, either key absent or null; `$role` such as `build agent` | `<language> <role>` with no framework; `<language> <role> with <frameworks>` with one or more; `Generic <role>` with no language |
| `capitalised` | a word | the word with its first letter in upper case |
| `seat_letter` | a seat name, such as `build-agent-alpha` or `build-agent-alpha-2` | its letter capitalised, with its round from the second one, such as `Alpha` or `Alpha 2` |
| `seat_display` | a seat name | its words with spaces, the first capitalised, then its letter as `seat_letter` gives it, such as `Build agent Alpha` |
| `seat_title($role; $seat)` | as `title`'s | `title`'s, with `$seat`'s letter right after the role word: `Rust build agent Alpha`, `Kotlin build agent Alpha with Spring`, `Generic build agent Alpha` |
