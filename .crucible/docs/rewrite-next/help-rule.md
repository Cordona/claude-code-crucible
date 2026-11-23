# The --help rule

Every `--help` lands in main's context when main reads it. Noise there costs context and buries what matters. A help holds exactly what a caller needs to call the script right, and nothing else.

**The reader is an agent first.** Write for an agent that will call the script: exact names, exact shapes, no persuasion, no narrative. A human reading it must still understand it, so use plain words, not shorthand only a parser would follow.

## Two requirements, both must hold

1. **Not verbose.** Every line earns its place: delete it and a caller would call the script wrong, or misread its result.
2. **Sufficient.** From the help alone, without reading the script, a caller understands what the script does and what it can do, when to use it, how to call it, what it prints, what it changes, and what each exit means.

## The template: every help, exactly this shape

Sections come in this order, each label exactly as written. A section with nothing to say is left out, except `Exit:`, which every help has.

```
usage: sh NAME.sh --req VALUE [--opt VALUE] [--many VALUE]... [--flag]

What it does, in one or two sentences, in caller terms. When to use it.

Options:
  --req VALUE    what it means
  --opt VALUE    what it means; default X
  --many VALUE   what it means; repeatable
  --flag         what it changes
Requires:  what the caller must have done first
Reads:     environment variables or stdin it reads
Writes:    the events, files or refs it changes, or "nothing"
Stdout:    the shape of what it prints
Exit:
  0  what success means
  2  refused, nothing changed; the reason is on stderr
  5  ...
```

- **Usage lines** follow the usual conventions: required options bare, optional ones in `[ ]`, repeatable ones with `...`, alternatives with `|`, placeholders in capitals (`FOLDER`, `NAME`, `FILE`, `SHA`). Every option the script accepts appears in a usage line and under `Options:`. `--help` and `-h` get no usage line: the reader has just run one. Absolute paths are marked once: `FOLDER, absolute`.
- **A script with commands** (`NAME.sh line ...`, `NAME.sh render ...`) has one usage line per command, then `Commands:` before `Options:`, one line per command, and each option says which command takes it when not all do.
- **Internal scripts:** the first line after the usage lines is `Run by <caller>; not for main to call.`
- **Hooks** say which hook event runs them and what they read from stdin; `Exit:` lists what each code does to the tool call or the stop.
- **Defaults, units and limits** go on the option's line: `default 60`, `seconds, 1 to 600`.
- **Exit codes** use the same meaning everywhere: 0 done; 2 refused, nothing changed, reason on stderr. Other codes are each script's own and say in a few words what happened and what to do (`6  the events lock stayed held: rerun`).
- **Stdout** names the shape (`one JSON object {commit, signed}`, `one path`, `nothing`); stderr is never described beyond "the reason".
- **Width** at most 80 characters. Labels and option names line up in one column within a help.

## A script main never calls

When only other scripts or a hook run it, say so first: `Run by <caller>; not for main to call.` Then keep the rest to what that caller needs. Main stops reading there.

## What a help never holds

- How the script works inside: algorithms, git plumbing, temp files, ordering.
- File layouts it keeps for itself.
- The full list of refusals: each refusal prints its own reason when it happens. Name only the refusals a caller can prevent by acting first, as the preconditions above.
- Validation details: give an input's shape (its keys, its type, one-line meaning), never every check the script makes on it. A value the script refuses with a clear reason needs no rule in the help.
- Why it was designed this way, history, other scripts' internals.
- Install facts: tool versions (jq 1.6+, git 2.31+) and the neighbour skills a script calls. The install check owns them; there is no `Needs:` section.
- Repetition: say each thing once.

## Size

About 8 to 15 lines, never more than 80 characters wide. Trimming that leaves a help as long as it was has not trimmed: look again for lines a caller can do without. A script with many options or exits may need more; each extra line must still pass requirement 1.

## Never changes behaviour

Trimming a help touches only the help text. The code, its options, its output and its exits stay exactly as they are. Anything a SKILL.md or another script tells the reader to find in this help ("its --help says…") must still be there.

## The checker

`tools/help-check.sh SCRIPT...` checks the template's shape: the usage lines, the labels and their order, no `--help | -h` usage line and no `Needs:` section, `Exit:`, the width, the length, every parsed option, and that a script's folder matches its help's first line. It prints nothing when every help passes.
