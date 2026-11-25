# The step 4 prose lines: Fable's review (2026-11-25)

By Crucible Fable Reviwer, for the owner. The owner's go is the only go.

**What I read:** Dev Beta's four items, against the report sections of the three definitions, the location section of `agent-report`, and which fields the reviewer's rules allow to span lines or leave out.

**Not done:** I ran nothing. I did not look up where run 3's `at: "description"` sat; section 2 asks Dev Beta to.

## Verdict

**Items 3 and 4 are approved as written. Items 1 and 2 each need one correction, and item 2 one check.**

| # | Line | View |
|---|---|---|
| 1a | "Each text is one line, about 200 characters." | **Approved for builder and tester. Wrong for the reviewer** |
| 1b | the summary "as a commit subject would say it" | **Change it** |
| 2a | the JSON array with its example | **Approved** |
| 2b | the two location sentences | **Approved, after one check** |
| 3 | what `applied` means | **Approved** |
| 4 | the mutation line | **Approved** |

## 1. The length line

**1a, the reviewer.** Its rules let `suggestion`, `proof` and `reply` run over several lines. "Each text is one line" would tell it to squeeze a fix into one line, which costs the builder that reads it. For the reviewer:

> Each text is one line, about 200 characters. A `suggestion`, a `proof` and a `reply` take the lines they need.

**1b, the summary.** "As a commit subject would say it" invites `fix: …`, and the rules refuse a summary that starts with such a prefix. It also points the agent at a commit it is told nothing about. With the cut in place a long summary costs nothing, so the line only needs to ask for short:

> `summary`: what you did, in one short line.

## 2. The location lines

**2a** is right: the example removes the comma-list reading.

**2b** reads well. One check before it runs: "takes no `at`" is only true where `at` may be left out. The reviewer's `noticed` requires it, and so do the builder's and tester's `decisions`. An agent that follows the sentence there is refused with "needs at", and has no way out.

So find the list run 3's `at: "description"` sat in. If `at` is required there, the fix is in that rule (make it optional for that list), and the sentence is then true. If it was already optional, nothing more is needed.

## 3. `applied`

Approved. It says what the check enforces, in the agent's words, and sits where the word is used.

## 4. The mutation line

Approved. "Undo the break" keeps its reason in the last sentence, and no longer asks for a folder the agent can't have.
