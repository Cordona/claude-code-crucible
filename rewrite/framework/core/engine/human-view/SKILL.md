---
name: human-view
description: "Shared jq modules for scripts' human views: `view.jq` (status line, sections, lists, Data section, whole paths), `paths.jq` (short paths cited for recognition), `title.jq` (developer or reviewer titles). Use when a script prints a view for the human. Loaded by scripts via `jq -L` and `include`; never by the model or the human. Writes nothing; needs jq 1.6+. Not for input checks or a view's content (each renderer's own)."
user-invocable: false
---

# Library: human-view

Shared jq modules for what renderer scripts print for the human. Scripts load them; the model never invokes this skill and the human never types it, so this file is for whoever writes or reviews a renderer. It writes nothing and runs nothing: a module only turns a value into display text.

## Rules

- **Every renderer goes through human-view:** a view's first line, sections, lists and Data section come from `view.jq`, and every path it prints from `view.jq` or `paths.jq`, never from a copy inside the renderer, so a fix lands once and every view looks alike.
- **A path the human may open is shown whole** (`path_text`): absolute, never `~`, never cut. `short_path` and `code_span` only for a path cited for recognition inside a line of text, never for a path handed over.
- **Helpers only:** a module formats values for display and checks nothing; validating input stays in the renderer that reads it, so loading a module never changes what a renderer accepts.
- **It grows by module:** a display function a second renderer needs becomes a module here, listed under Modules, and the renderers' own copies go.

## Layout rules

Every view a renderer prints for the human follows these; the def named after a rule builds it.

1. **First line:** a traffic light, a bold title, then optionally ` · ` and a count, or in a status view a state word. 🔵 a decision is needed; 🟢 done, nothing needs the human (no text saying so); 🟡 done, N items need the human, or a hint, which takes no count, or a state that needs the human's attention later (such as paused or dropped); 🔴 blocked. No other icon anywhere in the view (`status_line`).
2. **Headings are plain bold text, no icon:** a section's `**Name**` on its own line, or `**Name:** value` when it holds one item (`section`).
3. **Lists:** one item is a plain line with no mark; two or more are numbered (`1.`), never bullets (`section`). One exception: an offer's or a hint's list, placed right under the line it completes, is bulleted (`bullet_list`).
4. **Field lines** (Created, Modified, Deleted) are plain lines ending in two spaces (a hard break), a zero count left out (`field_lines`).
5. **A path the human may open** is whole and absolute: never `~`, never cut in the middle (`path_text`).
6. **Data last:** a view built from JSON in the Crucible space ends with that JSON's paths: one as `**Data · <Kind>:** <path>`, two or more as `**Data**` and a numbered `<Kind>: <path>` list (`data_section`). A view with no JSON behind it has no Data section. Three exceptions: a view repeated through one run (such as a grill round) shows its Data only on its last view, or in the view that follows the run (what-next after a grill); a one-line view carries its path inline, after its title; a status view ends with its folder's bare path.
7. **No constants:** a value that is the same on every view (a single agent, a single mode) is not shown, until a second value exists.
8. **Gates keep their `_Crucible gate_` marker,** which `open-gate.sh` adds; a renderer never prints it.
9. **The script prints, the model relays:** every view is printed by a script and relayed word for word; the model composes only the fixed one-line notices its skill spells out word for word.

Blocks of a view are joined by one blank line (`blocks`).

## Loading a module

A script passes the library folder to jq with `-L` and includes each module by its name, without `.jq` (illustrative: `<program>` is the renderer's own jq):

```sh
jq -L "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/human-view" -r '
include "view";
include "paths";
<program>' input.json
```

- **The `include` lines come first,** before any `def`: jq accepts module directives only at the start of a program, so a script that prepends shared definitions puts the includes ahead of them.
- **The skills dir is the script's:** a renderer loads human-view from the skills dir it resolves, so a test install finds its own copy.
- **Dependency:** jq 1.6+ (macOS: `brew install jq`; Linux: the distro's `jq` package).

## Modules

| Module | Holds |
|---|---|
| `view.jq` | A view's layout, as the Layout rules set: its status line, sections, numbered and bullet lists, plain lines, field lines, Data section and whole paths |
| `paths.jq` | Path and link display for a path cited for recognition: the shortening, the `~` form for the home folder, the middle cut and the 80-character cap, which keeps a code span on one line; and `link_span`, a whole path in backticks |
| `title.jq` | The one place a developer or reviewer title is built from a language label and framework labels; the caller passes the role word and never adds it itself |

`view.jq`'s public defs. A def returning `""` means nothing to show, and `blocks` drops it. Values arrive as cleaned display text: none cleans control characters.

| Def | Input | Output |
|---|---|---|
| `traffic_light` | status word: `decision`, `done`, `attention` or `blocked` | its glyph: 🔵, 🟢, 🟡 or 🔴 |
| `numbered_list` | array of strings | one `N. item` line per item, joined by newlines |
| `bullet_list` | array of strings | one `* item` line per item, joined by newlines |
| `plain_line` | one line of text | the line with a leading Markdown block mark (a heading, a quote, a rule, a list item or a code fence) backslash-escaped, so it shows as plain text at the start of a line or list item; inline Markdown stays as written |
| `path_text` | absolute path | the path whole, as plain text: no `~`, no cut, no backticks, so the terminal sees one path it can open |
| `status_line($status; $title; $tail)`, `status_line($status; $title)` | ignored | `<light> **<title>**`, then ` · <tail>` when `$tail` is neither `""` nor null |
| `section($name; $plural; $items)`, `section($name; $items)` | ignored | `""` for no items; `**<name>:** <item>` for one; `**<plural>**` and a numbered list for two or more (`$plural` defaults to `$name`) |
| `field_lines($pairs)` | ignored; `$pairs` an array of `[name, count]` or `[name, count, tail]` | one `<name>: <count>` line per non-zero count, with ` · <tail>` when given, joined by a two-space hard break; `""` when every count is zero |
| `field_section($heading; $pairs)` | ignored | `$heading`, a hard break, then `field_lines($pairs)`; `""` when every count is zero |
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
| `dir_segments` | absolute path | array: its folders, without the leading `/` or the basename |
| `home_form($home)` | string | the input with a leading `$home` folder written as `~`; unchanged when `$home` is empty or isn't its start |
| `short_path($home)` | string | `home_form`, then capped, with the basename kept whole when it is at most `span_cap - 2` characters |
| `shared_start($next)` | array | the longest start it shares with array `$next` |

`title.jq`'s public defs:

| Def | Input | Output |
|---|---|---|
| `joined_labels` | array of labels | `A`, `A and B`, or `A, B and C` for three or more, in the given order |
| `title($role)` | `{language: label, frameworks: [labels]}`, either key absent or null; `$role` such as `developer` | `<language> <role>` with no framework; `<frameworks> <role> with <language>` with one or more; `Generic <role>` with no language |
