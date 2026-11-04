# Self-documenting code: development

## Reporting

- **Each comment you keep against a bar:** record it, and why it stays, because a comment over a proportionality bar, or one that reads as REDUNDANT, is kept only on load-bearing grounds. Record any other kept WHY comment only when it could be flagged.
- **History a future editor doesn't need** (why this design, and what was tried first when that is the why): record it.

## Self-check before reporting

1. Every comment and docstring you wrote or changed is WHY, FUNCTIONAL or PUBLIC-API DOC; each REDUNDANT one is gone and its fix is in the code.
2. No comment says what the code does where a rename, an extraction or a named constant would, and no function exists only to avoid a sentence of rationale.
3. Every public surface you added or changed documents its behaviour, failure conditions and non-obvious constraints without restating the signature; no internal member got a docstring by rote.
4. Every name you added says what it does or holds, booleans read as a question, no number is unnamed, and nothing is abbreviated to save typing.
5. The volume and extreme-instance bars were run over the change, and the placement bar against the code only.
6. The project's comment and docstring conventions were followed.
