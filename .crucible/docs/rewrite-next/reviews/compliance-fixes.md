# Compliance fixes: the design (2026-11-21)

By Crucible Fable Reviwer, on the owner's instruction: fix every breach and concern of `reviews/compliance-audit.md`, so the new rewrite is fully compliant. This file is the design for each fix. It is already reviewed (I wrote it), so after the owner's go in Beta's session it can be built as it stands. Where building shows a design here is wrong, stop and say so; don't work around it.

Each fix says what is wrong, what to build, and what shows it is done.

## Order

1. F1 (the shared reader and file helpers), because F2, F5 and F8 use it.
2. F8 (the writer finds its own rules), because it changes every writer call once.
3. F2, F3, F4, F5, F6, F7.
4. F9 (the installed layout), last among the scripts, so its evidence run covers everything above.
5. F10 (the docs), when the scripts are settled.

## F1. One reader beside the one writer (audit C1)

**Wrong:** nine places list, sort and join an effort's event files, each its own way; one doesn't sort. The sha256 of a file is worked out in three places, and the write-through-a-temp-file in three.

**Build, in `crucible-events/scripts/`:**
- `events-read.sh --effort FOLDER [--type TYPE] [--paths]`. Prints the effort's events in seq order as one JSON array; with `--type`, only that type (a trailing `.*` takes a family, as `effort.*`); with `--paths`, the files' absolute paths, one per line, in place of the array. Reads only. An effort with no events prints `[]`, or nothing with `--paths`.
- The listing itself lives once, in `lib/`, used by both `events-read.sh` and `event-write.sh`.
- `lib/sha256.sh` and `lib/atomic-write.sh`: one function each, sourced, in the style of `lib/lock.sh` (no trap, no refusal of its own).

**Then replace every copy:** the effort library's summary, `gate-answer.sh`, the flow library's `fl_events`, the flow hook, `context-verify.sh`, the context library's latest version, `body.sh`'s look for the newest `spec.approved`, `spec-approve.sh`'s used-once read, `grill-list.sh`'s ended grills; `cx_sha256`, and the inline sha256 in `spec-approve.sh` and `flow-agree.sh`; `og_write`, `cx_write`, and the write inside `gr_save`.

**Not part of this:** the three `*_refuse` helpers and the three open-effort checks stay where they are. They are three lines of use, each with its own wording, not copies of logic.

**Done when:** no script but the shared listing names the events folder's file pattern (a search for `[0-9]*-` in `new-rewrite/` finds it in one file); every evidence run gives the output it gave before.

## F2. The flow's rule stops reading gate answers (audit B2)

**Wrong:** `flow.agreed.jq` checks the answer's type, the hook's name, the record and `accepted`. That is the gate's reader's job, and `flow-agree.sh` already asks it.

**Build:** the rule keeps the flow's shape, `answer` being a number, and used-once (no earlier `flow.agreed` with that answer). Nothing about `gate.answered`.

**Done when:** the rule file doesn't contain `gate.answered` or a hook's name; the evidence cases "refused without the recorded yes", "yes then no" and "the same yes twice" still pass, now refused by `flow-agree.sh` or by used-once.

## F3. The agreement card gets its own script (audit C4)

**Wrong:** `flow-show.sh --file` renders the card for a flow not yet agreed. That is a second job.

**Build:** `flow-card.sh --file FLOW` with that job alone; `flow-show.sh` loses `--file`. The shape check both use stays in `flow-replay.jq`.

**Done when:** `flow-show.sh --help` describes one job; the agreement path in the evidence uses `flow-card.sh`.

## F4. The question hook says what it does (audit C3)

**Wrong:** `hold-question-until-card-shown.sh` holds the question, checks a recorded gate's question, leaves the hand-off for the answer, and clears the card. Its name and header state the first.

**Why it stays one hook:** hooks on one matcher run side by side. The hand-off and the clearing both need the card's record at the moment the question is allowed, so a second hook would race the first.

**Build:** no behaviour change. Its header and `--help` state all of it, in the order it happens, and say in one line why it is one hook.

**Done when:** a reader of the `--help` alone could list everything the hook writes and removes.

## F5. The flow hook reads events as JSON (audit C5)

**Wrong:** it finds a session's efforts by searching for the text `"claude_session_id": "<id>"`, which depends on how the writer spaces its JSON.

**Build:** a cheap first pass that searches the event files for the bare session id (it holds whatever the spacing), then the real test through `events-read.sh` and jq on the `claude_session_id` field. The replay input comes from `events-read.sh` too.

**Known and left:** the hook still looks at every effort at each stop. Pruning old efforts bounds that; it is recorded as not built.

**Done when:** an event written with different spacing (one compact line) is still found; the hook's evidence cases are unchanged.

## F6. Prose that restates a script's rule (audit C6)

The test for each sentence: does a script refuse exactly this, so that the refusal alone would teach it?

| Skill | Sentence | Action |
|---|---|---|
| `crucible-grill` | "A changed answer needs its reason." | Remove. `grill-answer.sh` refuses without it and says why. |
| `crucible-spec` | "Every send of agents needs an approved one, as small as the work: a one-line fix gets a few lines." | Keep the second half; drop the first. The cut refuses without an approved spec. |
| `crucible-gate` | "puts the recommended option first, its label ending `(Recommended)`, and says why" | Reword so the marker's text isn't repeated: the recommended option first, marked as in the example, with its why. The example carries the literal. |
| `crucible-effort` | "Don't work on a paused or closed effort until it's resumed." | Keep. Scripts refuse only their own writes; work in a repository is conduct no script sees. |
| `crucible-gate` | "leaves room for the human's own words" | Keep. It tells main not to add an option of its own; the hook only catches two spellings. |
| `crucible-context` | "A version sent to agents never changes: what you add or take out later goes into the next version" | Keep. It says where later changes go, which no refusal says. |

**Done when:** the two removals and the one rewording are in; nothing else in those files changes.

## F7. A `--help` describes its own contract only (audit C7)

**Wrong:** `spec-approve.sh --help` and `flow-agree.sh --help` tell main which options of `show-card.sh` to pass.

**Build:** each says what the gate must have recorded, in its own terms: the record's name (`spec-approval`, `flow-agree`), the subject (the file's sha256), and that the human picked the option named as yes. No other script's name or flags.

**Done when:** neither help names `show-card.sh`.

## F8. The writer finds a type's rule itself (audit C8)

**Wrong:** the caller passes `--rules DIR`. So "one rule file per event type, owned by its component" is a habit: any caller can bring a rules folder of its own.

**Build:** `event-write.sh` drops `--rules`. It looks for `<component>/events/<TYPE>.jq` in the components beside `crucible-events`, and refuses when it finds none, or more than one, naming them. Every caller drops the option.

**What this gives:** one rule per type is enforced, a new component's events need no registration, and each writer call is shorter.

**Done when:** `--rules` appears nowhere in `new-rewrite/`; a type with two rule files in a scratch copy is refused, naming both; every evidence run gives the output it gave before.

## F9. Everything works installed (audit B1)

**Wrong:** the two domain scripts reach core by a path six folders up from their own. Through a skill link, which is how main runs them, that path doesn't resolve, and both exit 2. No evidence run goes through links.

**The cause, precisely:** a path through a link followed by `..` is resolved from the link's real target. Core's components are real neighbours, so `../../crucible-effort` works for them either way. A domain component's real neighbours are not core.

**Build:**
- A domain script finds core as a neighbour skill of the installed layout: its own skills folder, taken from its own path by cutting the last two parts as text (no `..`), then `<skills folder>/crucible-context/scripts/…`.
- When core isn't there, it refuses in one plain line: core's context isn't beside this skill; install first.
- So a domain component runs only installed. Say that in its `--help`.
- One new evidence run, `installed-run.sh`: make a scratch Claude folder, run the link commands `install-entries.sh` prints, and call at least one script of every component through the links: effort, context, grill, spec, flow, gate, both domain components in full, `effort-close.sh` seeing a domain neighbour's `open-work.sh`, and `install-check.sh` reading `installed`.
- `tracker-run.sh` and any other domain evidence run through that layout from now on.

**Done when:** `installed-run.sh` passes from `/`; the domain scripts work through links and refuse plainly when run where core isn't beside them.

## F10. Each spec says the current design once (audit C10)

**Wrong:** `HANDOFF.md`, `crucible-gate.md`, `context-analysis.md` and `grill-analysis.md` hold a first design with later sections overruling it. `effort-events.md` ends in two update lines that change its tables.

**Build:** as was done for `dynamic-flow.md`. Each becomes one current spec named for its component (`crucible-gate.md` with the answer events folded in or linked, `crucible-context.md`, `crucible-grill.md`, `crucible-effort.md`), saying what is built and why in a few lines of "decided, and why". The old files move to `specs/history/`. `HANDOFF.md` becomes: where things stand, what is built, what is recorded and not built with its trigger, and how we work. Its earlier sections move to history.

**Done when:** no spec in `specs/` contradicts the code or itself; no section says "superseding the lines below".

## The accepted pair, written down (audit C2)

No code change. The context reads the spec's `spec.approved` event (after F1, through the reader), and `spec-approve.sh` writes `spec.md` into the context's folder. That is coupling by event and by one public script, in both directions, and it is deliberate: the cut is the one place an unapproved spec can be stopped. State it in `crucible-context.md` and `crucible-spec.md` (F10), so it is known as the one such pair and not copied as a pattern.

## Not changed

- **Every question carries a recommended option (audit C9).** That is the owner's rule. It stays, and the live run shows whether main is ever forced to invent a recommendation.
- **The guard on the writer and `tracker-read.sh` (audit N1).** Both do one job from outside. Left as they are.
- **Three question examples in three skills (audit N2).** The owner's rule that each prose piece stands alone.

## What I will check

1. Each "done when" above, by reading the result.
2. Every evidence run, rerun from `/` in my own scratch space, against its earlier output: effort, context, grill, spec, gate-answers, dynamic-flow, fixes, tracker (by its output only: it calls the trackers), and the new `installed-run.sh`.
3. The audit's own measures again: the dependency map, the mention map, and the count of places that read events.
