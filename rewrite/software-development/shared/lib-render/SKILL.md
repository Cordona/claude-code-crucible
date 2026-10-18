---
name: lib-render
description: Shared jq modules that format what renderer scripts print for the human, first `paths.jq` for path and link display (the `~` form, a middle cut, an 80-character cap). Use when a renderer script shows a path, link or file name. Scripts load it by path with `jq -L` and `include`, so the model has no reason to load it and the human never types it. Writes nothing; needs jq 1.6+. Not for checking input (each renderer validates its own) or a report's layout (its renderer owns it).
user-invocable: false
---

# Library: lib-render

Shared jq modules for what renderer scripts print for the human. Scripts load them; the model never invokes this skill and the human never types it, so this file is for whoever writes or reviews a renderer. It writes nothing and runs nothing: a module only turns a value into display text.

## Rules

- **Every renderer goes through lib-render:** a path, link or file name any renderer prints for the human is formatted by `paths.jq`, never by a copy inside the renderer, so a fix lands once and every plan and report shows paths alike.
- **Rendering helpers only:** a module formats values for display and checks nothing; validating input stays in the renderer that reads it, so loading a module never changes what a renderer accepts.
- **It grows by module:** a display function a second renderer needs becomes a module here, listed under Modules, and the renderers' own copies go.

## Loading a module

A script passes the library folder to jq with `-L` and includes the module by its name, without `.jq` (illustrative: `<program>` is the renderer's own jq):

```sh
jq -L "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/lib-render" -r '
include "paths";
<program>' input.json
```

- **The `include` line comes first,** before any `def`: jq accepts module directives only at the start of a program, so a script that prepends shared definitions puts the include ahead of them.
- **The skills dir is the script's:** the plan renderer, render-dispatch-plan.sh, loads lib-render from the skills dir it resolves (`--skills-dir`, or the default above), so a test install finds its own copy.
- **Dependency:** jq 1.6+ (macOS: `brew install jq`; Linux: the distro's `jq` package).

## Modules

| Module | Holds |
|---|---|
| `paths.jq` | Path and link display: the path shortening, the `~` form for the home folder, the middle cut, and the 80-character cap on every shown path or link, which keeps a code span on one line beside its bullet |

`paths.jq`'s public defs. Each reads a string and returns a string unless its row says otherwise. None cleans control characters, so clean a value before passing it:

| Def | Input | Output |
|---|---|---|
| `span_cap` | none | 80, the most characters a code span holds |
| `cut_head` | none | 30, the characters a middle cut keeps before its `…` |
| `middle_cut($tail)` | string | its first `span_cap - 1 - $tail` characters, `…`, then its last `$tail` |
| `capped` | string | the input, or when over `span_cap`, its first `cut_head` characters, `…` and its last 49 |
| `code_span` | string | the input capped and in backticks, each backtick in it shown as `'` |
| `base_name` | string | the text after the last `/` |
| `dir_segments` | absolute path | array: its folders, without the leading `/` or the basename |
| `home_form($home)` | string | the input with a leading `$home` folder written as `~`; unchanged when `$home` is empty or isn't its start |
| `short_path($home)` | string | `home_form`, then capped, with the basename kept whole when it is at most `span_cap - 2` characters |
| `shared_start($next)` | array | the longest start it shares with array `$next` |
