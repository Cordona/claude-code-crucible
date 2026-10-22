# Clean code: review

Apply after `SKILL.md`'s rules when judging code by the clean-code rules: judge the change by every rule there, then apply these. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

- **Flag only a concrete harm:** name what the structure costs in this code, such as one change that must now be made in two places, a flow the reader must follow backward, or dead code that misleads. If no harm can be named, don't flag it.
- **Clarity is the goal, not compliance:** a principle followed for its own sake gains nothing, and a principle not applied is no finding by itself.
- **No structural surface, no finding:** pure config, docs, generated code or one-line trivia gets none; say so, and never manufacture one.
- **Never flag an order the language forces:** a declaration placed before its use because of a temporal dead zone or a forward-reference rule follows `SKILL.md`'s file-layout exception.

## Severity

Where a clean-code defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - none for this lens.
- **HIGH:**
  - a god function or class that hides a real bug right now (see Overrides).
- **MEDIUM:**
  - tight coupling that blocks change or testing (it raises the cost of the next change and ships no defect);
  - a god function or class (a clear single-responsibility break);
  - duplicated knowledge that needs parallel edits;
  - a premature abstraction that adds real complexity.
- **LOW:**
  - a file-ordering deviation (public after private, helpers out of call order).

**Overrides:**
- A god function that hides a real bug: report the bug itself, at HIGH.
- "It blocks testing" never raises a structural finding: it ships no defect.

**What moves a level:**
- A file-ordering deviation rises to MEDIUM when it is pervasive.
