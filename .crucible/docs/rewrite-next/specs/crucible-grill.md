# Spec: crucible-grill

A grill is an interview that helps the human decide what they don't know yet. Main asks a few questions at a time, each with a recommended answer and why; the human decides, until both share one understanding. The skill holds the judgment; the scripts hold the state, and each script's `--help` is its contract.

## The pieces

| Script | Its one job |
|---|---|
| `grill-new.sh --effort --topic` | Creates the draft with the next grill number in the effort, counting open and ended grills; prints its path |
| `grill-add.sh --grill (--question --recommendation --reason [--parent])...` | Appends open questions with the next free ids; prints the ids |
| `grill-answer.sh --grill (--id --text [--change-reason])...` | Records answers and settles the questions |
| `grill-mark.sh --grill --id --to dropped\|deferred\|open --reason` | Drops, defers or reopens one question |
| `grill-show.sh --grill [--open]` | Prints a draft or an ended grill: counts, then each question (only the open ones with `--open`) |
| `grill-end.sh --grill` | Writes the `grill.ended` event, removes the draft, prints the event's path |
| `grill-list.sh --effort` | Lists open and ended grills, newest first: path, state, open count, topic |
| `open-work.sh --effort` | Prints one line per open grill; `effort-close.sh` refuses while it prints any |
| `lib/grill.sh` | Shared by the scripts: paths, refusal, open-effort check, lock, shape check, atomic write |
| `lib/grill-shape.jq` | The grill's shape, in one home |
| `events/grill.ended.jq` | The event's rule |

## The draft

An open grill is a mutable file, `<effort>/grills/<n>.json`:

```
{number, topic, questions: [{id, text, parent?, recommendation: {text, reason}, status, answers: [{text, change_reason?}]}]}
```

- `id` is `q<N>`, unique; `parent` must name an earlier question. Every text is one non-blank line.
- Statuses: `open`, `settled`, `deferred`, `dropped`. A settled question has at least one answer.
- New questions start `open` with no answers.
- An answer settles an open or deferred question. A settled one changes only with `--change-reason`: the new answer is appended, earlier ones are kept, and its settled direct children not answered in the same call go back to `open`.
- An answer to a dropped question is refused; it is reopened first with `grill-mark.sh --to open`.
- `grill-mark.sh` to `dropped` or `deferred` appends a note, `Dropped: <reason>` or `Deferred: <reason>`; to `open` it appends nothing. It refuses a question already in that status.
- Every writer refuses unless the effort is open, takes the effort's grill lock (`grills/.lock`), checks the whole result against the shape, and writes through a temp file. A refusal writes nothing.
- The readers (`grill-show.sh`, `grill-list.sh`, `open-work.sh`) take no lock and work in any effort state.

## The event

`grill-end.sh` writes the draft as the body of one `grill.ended` event and then removes the draft, so the event is the single copy of an ended grill. Its rule checks the same shape, refuses a number already ended in the effort, and caps the event at 65536 bytes. Open and deferred questions stay as they are: an ended grill is not all decisions.

The grill does not call the context. Main gives the grill to the agents by adding the event's path with `context-add.sh --path <event> --why <line>`; it becomes a pending entry and reaches the agents with the next context version.

## Reading a grill

The `answers` list holds answers and notes alike. A reader reads `status` first:

- `settled`: the last entry is the answer; earlier entries, with their `change_reason`, are history.
- `dropped` or `deferred`: the last entry is the note saying why.
- `open`: no answer counts, even when entries remain from before a reopen.

`grill-show.sh` follows this rule: it prints "answer" for a settled question and "last note" otherwise.

## Decided, and why

- One script per job, so each is callable alone and its `--help` is its whole contract.
- The draft stays mutable until the end and only the end is an event: answers change often during a grill; the ended grill is the fact agents read.
- One copy, the event, referenced from the context: two copies would drift.
- `grill-end.sh` only writes the event; main adds it to the context, so the grill knows nothing about the context.
- A lock, not a prose rule, keeps writers from racing; it is the shared lock from `crucible-events`.
- Rounds are not in the shape and no script asks them: main builds each round from `grill-show.sh --open`, as a small card and one question dialog, or a plain sentence when there are no real options.
- Text limits are only "one line" and the event size, so the human's meaning is never cut.
- A changed answer reopens settled children: they were decided on the old answer.
- Effort close refuses while a grill is open, through `open-work.sh`, so a grill is never left behind unseen.

## Known limits

- A changed answer reopens direct children only, not grandchildren.
- Marking a settled question dropped, deferred or open reopens none of its children.
- A wrong question is dropped and re-added as a new one with the old as parent; ids never change.
- `grill-show.sh` does not check the shape of what it reads.
- A refused `grill-end.sh` leaves the draft in place; if the draft can't be removed after the event is written, a second end is refused because the number has already ended.
- When two grills decide the same thing, the grill says nothing about which wins; that is for the agents' side to read (the later event by seq).
