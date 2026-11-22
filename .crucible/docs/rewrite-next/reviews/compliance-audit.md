# Compliance audit of the new rewrite (2026-11-21)

By Crucible Fable Reviwer, for the owner. `new-rewrite/` judged against the constitution (17 values) and the prompting checklist (13 items).

**What I did.** Built a dependency map and a mention map from the files. Read all 11 prose files and all 70 scripts, rules and data files in full, for structure, not for bugs. Walked four scenarios on paper. Counted the files three kinds of change would touch. Ran one test of my own: the scripts through installed skill links.

**Size.** 3,805 lines in 81 files. 2,600 words of prose. The median script is about 50 lines; the largest is 188.

## Verdict

The rewrite keeps its constitution. The components are small, each owns its folder, its events and its rules, and a new component can be added without editing an existing one. Two things break a value outright and should be fixed before the live run. Ten more are concerns: places where the design is sound and the build is looser than the constitution asks.

## Your three questions

**1. Is coupling between prose and scripts avoided?** Nearly. Prose names a script in one place, and that is the allowed case (the gate skill tells main to run `show-card.sh`). No prose holds an exit code, an option list or a path into another component. What is left is the reverse kind: six sentences of prose that restate a rule a script already refuses (finding C6), and two `--help` texts that describe another component's options (C7).

**2. Are the components small, self-sufficient, DRY and single-job, and can main assemble them?** Small and single-job: yes. Self-sufficient: the core ones yes; the two domain ones fail once installed (B1). DRY: no, in one respect: reading an effort's events is written out nine times (C1). Assembly: all four scenarios compose on paper with no missing piece; no live session has shown it.

**3. Are the scripts truly single-job and lean?** Most are. Four carry more than one job or more code than their job is worth (C3, C4, C5, N1).

## Breaches: fix before the live run

**B1. The domain scripts fail when installed.** Verified by running them. `context-add-commit.sh` and `context-add-ticket.sh` reach core by a path six folders up from their own. Run through a skill link, which is how main finds them, that path doesn't resolve, and both exit 2. Core's scripts are fine through links. Every evidence run so far called the scripts by their real paths, so none could catch this. Value 17 (a script works where it is used); value 12 (evidence from how it really runs).
- Fix: the domain reaches core the way an installed layout offers, and one evidence run goes through an installed layout, links included.

**B2. `flow.agreed.jq` reads gate answers itself.** It checks the answer's type, the name of the hook that wrote it, its record and its `accepted` field. `gate-answers.md` says pieces never read the answers themselves; `spec.approved.jq` was fixed to hold only its shape and used-once, and this rule was not. It ties the flow to the gate's internals, hook name included. Values 11 and 15.
- Fix: the rule keeps the flow's shape and used-once; `flow-agree.sh` already asks `gate-answer.sh`.

## Concerns

**C1. Reading events is written nine times.** There is one writer, and no reader. `event-write.sh`, the effort library, `gate-answer.sh`, the flow library, the flow hook, `context-verify.sh`, the context library, `spec-approve.sh` and `grill-list.sh` each list, sort and join the event files their own way; one of them doesn't sort. The sha256 helper exists three times and the atomic write three. Value 11.
- Recommendation: one reader beside the one writer, in `crucible-events`. Each component still decides which events it reads.
- This revises my own earlier ruling, which shared only the lock.

**C2. The context and the spec know each other in both directions.** `spec-approve.sh` calls `context-docs.sh` and writes `spec.md` into the context's folder; the context's `body.sh` reads `spec.approved` events and their `sha256`. Neither can change alone. It came from my own change (the cut must check the approval). It is coupling by event, which value 4 allows, so I'd keep it and write it down as the one accepted pair.

**C3. `hold-question-until-card-shown.sh` does three jobs.** It holds the question, checks a recorded gate's question (one question, single-select, the yes option offered), and leaves the hand-off for the answer. Its name states the first. Hooks on one matcher run side by side, so a split would race; keep it as one, and say all three in its header and `--help`.

**C4. `flow-show.sh` does two jobs.** It shows a flow's track, and with `--file` it renders the card for a flow not yet agreed. The second is its own job and should be its own script. My recommendation at the time was "a mode"; that was wrong by value 17.

**C5. The flow's Stop hook is brittle and gets slower.** It finds a session's efforts by searching event files for the text `"claude_session_id": "<id>"`, which holds only while events are printed with exactly that spacing. And it searches every effort at every stop; with no pruning, that cost only grows.

**C6. Six sentences of prose restate a rule a script refuses.** They are the only prose that goes stale when code changes:
- gate: the recommended option's label ends `(Recommended)`; the human can always answer in their own words;
- grill: a changed answer needs its reason;
- spec: every send of agents needs an approved spec;
- effort: don't work on a paused or closed effort;
- context: a version sent to agents never changes.
Each saves main one refused call. If "at all cost" is the rule, the grill, spec and effort ones can go, since the refusal says the same. I'd keep the gate's (its example needs it) and the context's (it explains where later changes go).

**C7. Two `--help` texts describe another component's options.** `spec-approve.sh` and `flow-agree.sh` tell main how to call `show-card.sh`. If the gate's options change, both go stale. Say what the gate must record (the record's name, the subject), not which flags to pass.

**C8. `event-write.sh` trusts its caller for the rules folder and the writer's name.** "One rule file per event type, owned by its component" is a convention; any script can write any type with a rules folder of its own. Harmless today. It matters once domains and agents write events.

**C9. Every question must carry a recommended option.** The shape hook requires it on every `AskUserQuestion`, a pure-preference grill question included. The gate skill asks for an honest recommendation. Where main has no ground for one, the hook forces it to invent one. Value 7. Watch it in the live run.

**C10. The docs are layered.** `HANDOFF.md` and three specs (`crucible-gate.md`, `context-analysis.md`, `grill-analysis.md`) hold a first design with later sections that overrule it. The scripts match the later sections. A reader starting at the top builds the wrong thing; `dynamic-flow.md` was rewritten as one spec for this reason, and the others were not.

## Notes

- **N1. Two scripts are heavy for their value.** `deny-direct-event-write.sh` is 95 lines of shell word-parsing to stop a mistake that read-only events and the rules already blunt; I asked for it. `tracker-read.sh` is 188 lines holding the link rule, two trackers, timeouts, comments and the cut. Both do one job from outside. They are the first to look at if leanness is pressed.
- **N2. The question's shape is taught three times.** The gate, discovery and grill skills each carry a full `AskUserQuestion` example, about 450 of the 2,600 prose words. That follows your rule that each prose piece stands alone; the price is three files to change if the tool's input changes.
- **N3. Ceremony before work starts.** A routine effort passes an effort gate, a flow gate and a spec gate, each a card and a question, before anything is built, plus a card and a dialog per grill round. Each is one click. Count them in the live run against value 16.
- **N4. The envelope's fields kept for later readers** (`claude_session_id` for metrics, `iteration` for seats) are approved as they are and are not findings.

## The scenario walks

| Scenario | Composes? | What it leans on |
|---|---|---|
| Routine: effort, flow, discovery, spec | Yes | Main writing the flow file and the cards somewhere; no prose says where, and nothing needs it to |
| A change mid-way: the human adds a grill, skips a step | Yes | `flow-change`, the grill joining the open effort, the ended grill added to the context |
| Unforeseen: work with no fitting skill | Yes | Criterion steps, notes and references; `CLAUDE.md` stops main sending agents |
| Back after a break | Yes | The `CLAUDE.md` line, `effort-list`, `flow-show --effort`. A spec draft waiting for approval is found only through the flow's open step |

## The change tests

| Change | Files touched | Reading |
|---|---|---|
| Add a component with a hook and open work | 0 existing | The install and the close check both find it by scanning. This is the design working |
| Rename `effort-state.sh` | 4 | Three libraries and the flow hook each call it |
| Add a field to `gate.answered` | 2, and a third by B2 | The third goes away with B2 |
| Change `spec.approved`'s body | 3 | C2 |
| Change the question tool's input | 5 | Three skills and two hooks (N2) |

## The 17 values

| Value | Holds? |
|---|---|
| 1 Pieces, not pipelines | Yes |
| 2 Scripts for determinism, the model for judgment | Yes |
| 3 Invariants in code | Yes, for what is built. Still prose: no commit unasked, no agents |
| 4 Events are facts | Yes; read-only since today |
| 5 Hows, not flows | Yes; no how says what comes before or after it |
| 6 Thin prose | Yes; C6 is the remainder |
| 7 The human decides | Yes; C9 to watch |
| 8 Fast decisions | Unproven until live |
| 9 Token efficiency | Script output is compact; unmeasured (metrics is not built) |
| 10 Once acted on, sealed | Yes: events, cut versions, used-once answers |
| 11 Reuse, one home | Mostly; C1, B2 |
| 12 Small, then learn | The build is small. The learning has not started: no live run |
| 13 Safe by default | Yes; the install check changes nothing |
| 14 The agreed pipeline | Yes, with proof of the agreement |
| 15 Prose stands alone | Yes; one accepted mention (the flow example names the grill) |
| 16 Weight follows frequency | N3 to measure |
| 17 Small scripts, one job | Mostly; B1, C3, C4 |

## The prompting checklist

All 13 items pass on all 11 prose files. No self-check instructions, no reasoning formats, no finder with a filter. Length toward the human is set in `CLAUDE.md`. Each skill teaches by one positive example.

## Where this audit revises my own earlier rulings

- I shared only the lock; event reading should be shared too (C1).
- I asked for the agreement card as a mode of `flow-show.sh`; it is a second job (C4).
- I asked for the guard on the event writer; it is the least lean script in core (N1).
- My change to the cut tied the context to the spec's event (C2).
- I never asked for an evidence run through an installed layout, and B1 went unseen through nine reviews.

## What this audit does not show

How main behaves with any of it. Everything here is read from files and scripts run by hand.
