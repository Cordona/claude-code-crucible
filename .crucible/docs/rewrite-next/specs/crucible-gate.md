# Spec: crucible-gate

Every question main asks follows a card the human has seen. A decision a piece acts on is recorded as the human's own answer, never main's retelling.

**Home:** `new-rewrite/framework/core/main-thread/crucible-gate/`. Each script's and hook's `--help` is its contract.

## The pieces

| Piece | Its one job |
|---|---|
| `scripts/show-card.sh` | Prints a card for main to relay, and records it as owed this session |
| `scripts/gate-answer.sh` | Says whether the newest answer to a recorded gate accepted it |
| `scripts/lib/owed.sh` | The owed-card store: path, safe ids, 30-minute stale age, 2-try cap |
| `hooks/stop/require-card-shown.sh` | Keeps main going until its final message holds the owed card, then tells it to ask |
| `hooks/pre-tool-use/hold-question-until-card-shown.sh` | Holds the question until its card is shown, runs the shape check, checks a recorded gate's question and leaves the hand-off, then clears the session's cards |
| `scripts/check-question-shape.sh` | Run by the hold hook, not by main: denies a question that breaks the shape rules, naming each broken rule |
| `hooks/post-tool-use/record-gate-answer.sh` | Writes a recorded gate's answer as one `gate.answered` event |
| `events/gate.answered.jq` | The event's rule: its writer and its body's shape |
| `hooks/matchers.json` | The event and matcher for each hook: Stop with no matcher, the other two on `AskUserQuestion` |

## A card and its question

1. Main runs `show-card.sh <card file>` (a script's card or a short one of its own). It prints the card and records it as owed under `${CLAUDE_CONFIG_DIR:-~/.claude}/cache/crucible-gate/<session>/owed/`, replacing any card still owed.
2. Main ends its turn with the card. The Stop hook compares the final message with each owed card, ignoring trailing spaces and blank lines:
   - card missing: main is sent back to show it exactly as printed, at most 2 times. After that the record is dropped and the human gets a notice saying so;
   - card present: marked shown, and main is told to ask; again at most 2 times if it stops without asking.
3. Main calls AskUserQuestion. The hold hook denies it while there is no card or a card is still owed. Once a card is shown, the hold hook runs the shape check (4), then a recorded gate's check. Only when nothing refuses does the question go out and the session's card records are removed, so the next question needs a new card. A refused question leaves the card in place, so main fixes the question and asks again without showing the card again.
4. The shape check, as a step of the hold hook, checks each question:
   - the question text is not empty;
   - the first option's label ends with `(Recommended)`, and no other option's label does, unless the question is multi-select;
   - every option has a non-empty description, which says why;
   - no hand-made "Other" or "Something else": the dialog always offers one.

   The 2–4 option count is the tool's own check. The refusal for a missing recommendation also says that a question with no real options comes out of the dialog and is asked in a plain sentence. If the shape check can't run, the step is skipped: a hook fault never blocks the human.

All hooks ignore other tools and any call or stop from a subagent (a non-empty `agent_id`). Records older than 30 minutes are removed as stale.

## Recorded gates

A gate whose answer a piece will act on adds options to `show-card.sh`:

- `--record NAME`: what is decided, lowercase words joined by dashes, such as `spec-approval` or `flow-agree`;
- `--effort FOLDER`: the absolute folder of the effort whose log receives the answer;
- `--accept LABEL`: the option label that means yes;
- `--subject TEXT` (optional): what exactly is decided on, such as a file's sha256.

They are kept in the owed record. For a recorded card the hold hook denies anything but one single-select question offering the accept label, then writes a hand-off, `<session cache>/answers/<tool_use_id>.json`, holding the record and the question text. After the answer, the answer hook writes the event through `event-write.sh` and removes the hand-off; if the write fails, it says on stderr to ask again.

The `gate.answered` body:

| Field | Read by |
|---|---|
| `record`, `subject` | `gate-answer.sh`, which matches on both |
| `accepted` | `gate-answer.sh`; true only when the answer equals `accept` |
| `question`, `accept`, `answer` | no script; they show the human what was asked and what counted as yes |
| envelope `by` | `gate-answer.sh` and the rule; only `record-gate-answer.sh` may write this event |

A piece never reads these events itself; it runs `gate-answer.sh --effort --record --subject`. The newest matching answer counts, so a later "no" cancels an earlier "yes": `ACCEPTED: <seq>` and exit 0, or exit 1 with the reason. `spec-approve.sh` and `flow-agree.sh` use it, with the file's sha256 as subject. Whether an acceptance may be used twice is the caller's rule.

A typed answer never counts as acceptance, because it can't equal the accept label. The answer is written even while the effort is paused, since neither the writer nor the rule checks the effort's state.

## When the hooks don't run

The skill gives main the sign: its turn ended with the card and nothing told it to ask. At the human's next message, main says the hooks aren't running, suggests the install check in the framework's `install/` folder, then asks. Without the hooks a recorded gate leaves no event, so the piece that needs it refuses.

## Decided, and why

- **Every question needs a card:** a hook can check that; a narrower rule would make the hook judge which questions deserve one. A quick question stays a plain sentence.
- **Main writes the question:** no templates; it is built from the situation, and hooks check only its shape.
- **One hold hook, not several:** hooks on one matcher run side by side, so the shape check is a step of the hold hook, not a hook of its own: nothing is cleared while another check could still refuse the question. The hand-off and the clearing need the card's record at the moment the question is allowed.
- **Hooks fail open:** a fault exits 0, so a bug never blocks the human.
- **2 tries:** a copy slip is fixed in one or two; then the stop goes through instead of looping, and a dropped card is told to the human.
- **Card records are throwaway cache, not events:** edited and removed freely; only the answer is a fact.
- **`--accept` is declared before the answer:** no script can tell from a label that it means yes. The hook works out `accepted`; main never claims it.
- **One reader:** the reading rule lives in `gate-answer.sh` for every deciding piece.

## Known limits

- `accepted` is one yes/no; a gate with several acting options (which findings to fix) needs more when the first such piece arrives.
- Decisions outside an effort, such as starting one, leave no proof, until a piece needs it.
- No age limit on an answer; an age rule is the piece's own.
- A hand-off left by a failed write is never cleaned up.
