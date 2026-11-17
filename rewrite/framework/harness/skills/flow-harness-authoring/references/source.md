# Source: Explain and Specify

How the approved source of a skill flow is produced, read at Skill flow step 1: Explain for a refactor, Specify for anything else.

## Explain

1. Dispatch `skill-analyst` in `EXPLAIN` mode; save the reply as `explanation.md`.
2. Dispatch a second `skill-analyst` in `VERIFY` mode with that path; save the reply as `verify.md`.
3. On a missing card, or a `WRONG LINE` or `UNSUPPORTED` on a rule card's rule, source or enforcement: copy both files to `pre-fix/explain-r<n>/` (also before a G1 *Re-explain*), dispatch `skill-analyst` in `EXPLAIN` again with the correction brief (the old explanation and `verify.md`), and re-save its reply as `explanation.md` with `--force`; then one `VERIFY` of it, re-saved as `verify.md` with `--force`. Then G1 (`SKILL.md` Always, Cap the rounds). Any other `WRONG LINE` or `UNSUPPORTED` (a citation or claim that changes no card) goes to G1 as found, with no correction.
4. Add one line at the top of `explanation.md` naming the last `verify.md` and its counts.

## Specify

Draft `spec.md` with the human in these sections, each a `## ` heading: Purpose; When it fires, and when it doesn't; Steps, in order; Rule cards (`RULE-NNN`, each with its source and what enforces it: script, hook or prose); Inputs, outputs and state; Dependencies; Open questions. `SKILL.md` (Skill flow step 1) adds two rule cards to every source and defines the item IDs.
