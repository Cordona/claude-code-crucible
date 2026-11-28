# Gate hook fixes from live run 5: design

The owner asked for this design on 2026-11-22. Fable reviews it, and nothing is built before the owner's go.

## 1. A question refused for its shape uses up the card

**Cause.** Two PreToolUse hooks run side by side on AskUserQuestion:

- `hold-question-until-card-shown.sh` lets the question through and removes the session's card records;
- `check-question-shape.sh` refuses the same question.

The question never goes out, but the card is gone. The next try is refused with "Every question needs a card."

**Fix.** One hook decides whether a question goes out, and nothing is written or removed before every check has passed.

- `check-question-shape.sh` stops being a hook. It moves to `crucible-gate/scripts/` unchanged: same stdin, same deny JSON on stdout, same `--help`.
- `hold-question-until-card-shown.sh` runs it as a step, in this order:
  1. a card is held (as today);
  2. the shape check: if it prints a deny, the hook passes that deny on and exits, so no record is touched;
  3. the recorded gate's check (as today);
  4. the hand-off and the clearing (as today).
- `hooks/matchers.json` drops the `check-question-shape.sh` line.
- Each job keeps its own script. The hold hook already exists to sequence steps that must see the card's record at the moment a question is allowed. This adds one more step to that order; it is not a new hub.

- **When the shape check can't run** (the script is missing, or it fails): the step is skipped and the hook goes on as if the shape passed. That is what happens today when the separate shape hook breaks, and it keeps the gate's rule that a hook fault never blocks the human. A refusal here would block every question until someone repaired the install, and main can't fix that. If jq is missing, the hold hook already lets the question through before doing anything. The install check reports a missing script.
- **The moved script's `--help`** opens with: "Run by the question hook, on the hook's input; not for main to call."

**Rejected:** clearing the card in PostToolUse, after the question was really asked. When the human answers from the dashboard, the dialog is dismissed and PostToolUse doesn't run. The shown card would stay, and the Stop hook would send main back with "ask your question now". The owner answers that way often.

**Evidence run.** Run from a neutral folder through the real hooks:

- a badly shaped question after a shown card is refused for its shape, and the card is still there;
- the fixed question then goes out with no new card;
- a question with no card is still refused as today;
- a recorded gate (`spec-approval`): a badly shaped question is refused, the fixed question goes out with no new card, and the answer is written as `gate.answered` with the right record and subject;
- with the shape script removed, a well-formed question still goes out;
- the install check is clean once the matcher line is gone.

## 2. The shape refusal makes main invent a recommendation

**Cause.** A question only the human can answer has no real options to recommend. The refusal still says "the first option must be the recommended one", so main makes one up. The gate skill says such a question is asked in a plain sentence.

**Fix.** One change to the wording of that single refusal, in `check-question-shape.sh`:

> `<name>`: the first option must be the recommended one, its label ending with (Recommended). If there are no real options to recommend, take this question out of the dialog and ask it in a plain sentence.

The rule stays. No check of whether options are "real" is added, because a script can't judge that. Only the refusal names the way out.

**Watch.** If the plain question was the only one behind its card, the card stays shown and the Stop hook sends main back once or twice ("ask your question now") before it drops the card. Run 5's case was one question in a four-question dialog, so the rest of the dialog still goes out. Nothing is proposed for the lone case until a run shows it.

## Files touched

- `crucible-gate/hooks/pre-tool-use/hold-question-until-card-shown.sh`: the shape step, plus `--help`.
- `crucible-gate/hooks/pre-tool-use/check-question-shape.sh` moves to `crucible-gate/scripts/check-question-shape.sh`, with the new refusal wording.
- `crucible-gate/hooks/matchers.json`
- `specs/crucible-gate.md`
- the gate evidence run and its output.
