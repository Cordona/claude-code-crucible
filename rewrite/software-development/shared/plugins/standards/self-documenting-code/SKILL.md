---
name: standard-self-documenting-code
description: The rubric for comments, docstrings and names as documentation in any language, tests included, test names aside — a comment earns its place by saying why, names that carry the meaning, the four comment kinds, docstrings on a public surface, and three proportionality bars. Injected into the agent's first message when loaded. Writes nothing. Not for code structure (standard-clean-code), test-only rules (standard-testing), or doc-comment syntax or a stack's idioms (its tech plugin).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Self-documenting code
---

# Standard: Self-Documenting Code

What a comment, a docstring and a name are for, in any language. The developer builds to these rules, then follows `references/development.md`; a reviewer (once `code-reviewer` exists) judges by the same rules, then follows `references/review.md`. Both receive this file in their prompt (or by Read, implementing directly), with their role's reference file right after it.

## Scope

- **In:** every comment and docstring in the code the developer writes or changes, test code included, and every name in it except test and scenario names, at the same bar: a test with a docstring on every assertion is judged as a production module would be.
- **Project conventions:** follow the project's comment and docstring conventions: its doc sections, its tolerance for a WHY note's length and where it sits. Never impose a foreign house style. A convention never launders a defect: a REDUNDANT comment or an undocumented public contract is a defect even where the project does the same.

## Reading the rules

- **A documented, official language convention governs where it differs from a rule here;** a personal or house preference doesn't. This standard is the language-agnostic floor.

The burden of proof comes first: every rule after it applies it.

## 1. When a comment earns its place

- **A comment or docstring starts absent:** it earns its place only when the code as written can't say what a rename, an extraction or a named constant would say. A comment used in place of clear code is the failure this standard prevents.
- **A comment that would say what the code does: rename or extract instead,** so the code says it.
- **A comment that says why: keep it.** Why a choice was made is information the code can't always carry, so such a comment is a gain, not a compromise.
- **Never bend code to avoid a comment:** no squeezed names, no function extracted only to avoid one sentence of rationale, no logic forced out of its natural shape. Zero comments is not the goal.

- Bad: `// only admins may edit` above `if (user.role == 2)`. Good: `if (user.isAdmin())`, with no comment.
- Good, and kept: `// The bank rejects a second refund within 60 s, so wait before retrying.`

## 2. The four comment kinds

Every comment is one of four kinds. WHY and PUBLIC-API DOC are documentation; FUNCTIONAL is kept but isn't documentation; everything else is REDUNDANT.

- **REDUNDANT: remove it, and put the fix in the code.** It restates the code; makes up for a bad name or an overlong unit; logs changes (version control keeps that history); exists only because every function must have one; marks a position or draws a banner; names an author; is commented-out code; or is a `TODO` with no owner.
- **WHY: keep it.** It gives a workaround with its issue link, a non-obvious order, a non-obvious algorithm or derivation, a constant from an external spec, a deliberate deviation, a warning of a non-obvious consequence, an easily missed detail, a legal or regulatory notice, or a `TODO` with an owner.
- **FUNCTIONAL: keep it,** since a tool reads it: a shebang, a license or SPDX header, a lint or type suppression (`# noqa`, `@ts-expect-error`, `#[allow(...)]`, `# shellcheck disable=`), a build directive (`//go:build`, `//go:generate`, `#[cfg(...)]`), a coverage pragma, or an annotation a framework acts on.
- **PUBLIC-API DOC: keep it.** A docstring on a public surface (a function, method or class that code outside its module, or outside the codebase, depends on) is a contract with its callers; it is REDUNDANT only when it restates the signature.

## 3. Docstrings

- **A public surface documents its contract:** what a caller needs and can't get from the signature, such as its behaviour, its failure and error conditions and its non-obvious constraints.
- **Internal and private code gets no docstring by rote, and no exemption either:** its comments are judged by the WHY test above, never by a rule that every member needs one.
- **Never restate what the language already says:** a return type, a nullability guarantee or an error channel the signature expresses is REDUNDANT in prose.
- **An example in a docstring shows a non-obvious use, or is left out:** one that only shows the calling syntax is decoration.
- **Apply these rules through the stack's doc-comment form;** its syntax, its conventional sections and how strictly a docstring's presence is enforced are out of this standard.

## 4. Names

The name is the documentation.

- **Functions:** a verb and a noun that name the action, such as `sendInvoice()`.
- **Variables:** what they hold, such as `unpaidInvoices`.
- **Booleans:** read as a question, such as `isExpired` or `canRetry`.
- **Constants:** name the meaning, so no number appears unnamed, such as `SESSION_TIMEOUT_SECONDS`.
- **Classes and types:** a noun that names the responsibility, such as `InvoiceSender`.
- **Never abbreviate to save typing** (`d`, `tmp`, `data2`): a name that hides its intent is a defect even when the code compiles.

## 5. Proportionality

- **Length is checked whatever the kind:** a WHY or PUBLIC-API DOC comment much longer than what it documents (its function, method, class or module, or the field or declaration it sits on) is a trigger to look, not a limit.
- **Each bar below is judged on its own,** never by another's.
- **Volume:** a ratio (a comment's line count over the code line count of what it documents) of about 2:1 or more that recurs in 2 or more units of the same diff. One long docstring alone, below the extreme bar, is not a pattern.
- **Extreme single instance:** a ratio of 5:1 or more and a comment block over about 8–10 lines; both gates must hold, and one instance is enough. A 6-line comment over a 1-line field clears the ratio but not the length gate.
- **Placement:** the same fact stated in 2 or more places, such as a code comment and the commit message, or a code comment and the PR or MR description. One instance is enough, even when every copy is accurate: the duplication is the problem.
- **Where a load-bearing fact lives:** keep in the file the copy a future editor needs with nothing else open. The history (why this design, what was tried first) goes in the commit or PR, where that question is searched for.
