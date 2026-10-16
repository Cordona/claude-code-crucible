# Self-documenting code: development

Apply after `SKILL.md`'s rules, before writing code.

## Reporting

- **Name each comment you keep against a bar** in the report's Key decisions field, with why it stays: a comment over a proportionality bar, or one that reads as REDUNDANT, is kept only on load-bearing grounds, and the reviewer judges it by them. Example: `Kept the 12-line note on parseRetryAfter(): the header's two formats come from RFC 9110 and can't be named away.`
- **Split a fact the file and the commit both need** in Key decisions as `kept in file: <X>; for the commit message: <Y>`, the form `standard-code-development-report` sets; the split itself is SKILL.md's "Where a load-bearing fact lives".

## Self-check before reporting

1. Every comment and docstring you wrote or changed is WHY, FUNCTIONAL or PUBLIC-API DOC; each REDUNDANT one is gone and its fix is in the code.
2. No comment says what the code does where a rename, an extraction or a named constant would, and no function exists only to avoid a sentence of rationale.
3. Every public surface you added or changed documents its behaviour, failure conditions and non-obvious constraints without restating the signature; no internal member got a docstring by rote.
4. Every name you added says what it does or holds, booleans read as a question, no number is unnamed, and nothing is abbreviated to save typing.
5. The volume, extreme-instance and placement bars were run over the change, and each comment kept over a bar is in Key decisions.
6. The project's comment and docstring conventions were followed.

A failed item: fix it, then run the check again.
