# Clean code: review

- **No finding without a concrete harm:** name what the structure costs in this code, such as one change that must now be made in two places, a flow the reader must follow backward, or dead code that misleads.
- **No structural surface, no finding:** pure config, docs, generated code or one-line trivia gets none.

## Severity

- **CRITICAL:**
  - none for this lens.
- **HIGH:**
  - none for this lens.
- **MEDIUM:**
  - tight coupling that blocks change or testing;
  - a god function or class (a clear single-responsibility break);
  - duplicated knowledge that needs parallel edits;
  - a premature abstraction that adds real complexity.
- **LOW:**
  - a file-ordering deviation (public after private, helpers out of call order).

**Overrides:**
- "It blocks testing" never raises a structural finding: it ships no defect.

**What moves a level:**
- A file-ordering deviation rises to MEDIUM when it is pervasive.
