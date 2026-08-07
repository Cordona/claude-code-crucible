---
name: standard-git-commit
description: The single definition of a good git COMMIT — the shared rubric the git-operator builds every commit to. Applies whenever a commit is created (by the operator, or by an orchestrator/flow committing directly). Covers Conventional Commits format, message craft (imperative, subject/body/wrap), structured bodies, the footer trailer block (Signed-off-by / Co-authored-by / issue links), atomicity (one self-compilable concern per commit) and cross-cutting splitting, mandatory signing + identity verification (via procedure-git-identity), and the client/server enforcement layer. It does NOT define branch naming (standard-git-branch), release tags (standard-git-tag), or how the signing identity is resolved (procedure-git-identity — bound alongside this).
---

# Standard: Git Commit

The **one** definition of a good commit. The `git-operator` authors every commit to it; anything that commits directly (an orchestrator, the external-review flow) follows it too. A commit is a **permanent, signed, attributable** record — treat it as an artifact, not a checkpoint.

## The format — Conventional Commits

```
<type>[(scope)][!]: <description>      ← subject (header)
                                       ← blank line (required)
<body>                                 ← what & why, wrapped at 72
                                       ← blank line
<footer>                               ← author trailers: issue links, Co-authored-by (Signed-off-by is auto-appended — see below)
```

- **type** (lowercase, required): `feat` · `fix` · `docs` · `style` · `refactor` · `perf` · `test` · `build` · `ci` · `chore` · `revert`. (`feat`/`fix` are spec-mandated; the rest are the conventional superset.)
- **scope** (optional): a parenthesized noun naming the area — `feat(auth):`, `fix(parser):`.
- **`:` + single space** before the description. Type stays lowercase; the description is lowercase too (do NOT capitalize the header — that Beams rule is overridden by Conventional Commits).
- **breaking change** — signal it **both** ways when it applies: a `!` before the colon (`feat(api)!:`) **and/or** a `BREAKING CHANGE: <what broke + migration>` footer (uppercase token). Either drives a MAJOR version bump (see `standard-git-tag`).

## Subject line (the header)

- **Imperative mood** — "add", "fix", "refactor", never "added"/"adds"/"fixed". Test: *"If applied, this commit will ___."*
- **≤ 50 characters target, 72 hard limit** (including the `type(scope):` prefix). Detail belongs in the body, never a longer subject. *(This replaces a "minimum length" rule — a minimum forces padding of good short subjects like `fix(auth): reject expired token`.)*
- **No low-content subjects.** The description MUST name the change specifically — never `fix`, `update`, `wip`, `stuff`, `changes`. This is the quality bar; length is not.
- **No trailing period.**

## Body

- **Blank line between subject and body** (git treats text up to the first blank line as the title — tooling breaks without it).
- **Explain WHAT the commit brings and WHY**, not how (the diff shows the how). Concise — clean and complete, not verbose.
- **Wrap at ~72 columns** (git never wraps for you).
- **More than one thing happening → a bullet list:**
  ```
  - Extract the retry policy into a reusable backoff helper
  - Cap retries at 5 and add jitter
  - Cover the exhausted-retry path with a test
  ```
  (But if a commit needs several *unrelated* bullets, that is usually a sign it should be **split** — see Atomicity.)

## Footer — the trailer block

One block at the end, each `Token: Value`, hyphenated tokens, no blank lines between trailers:
- **`Signed-off-by: Name <email>`** — **REQUIRED on every commit** (DCO provenance), but **appended automatically by `commit.sh`'s `git commit --signoff` — do NOT hand-write it into the message.** It is the one trailer the SCRIPT owns, not the author: it is derived from the committer identity that `procedure-git-identity` resolves and reconciles, so a message author (the `git-operator`, or any flow committing directly) **leaves it out** and lets the script write that byte. Hand-authoring it duplicates the trailer whenever it isn't a byte-identical last line (e.g. a `Co-authored-by` follows it). The resulting email MUST match the committer identity (see `procedure-git-identity`).
- **Issue link** (recommended) — `Closes #123` / `Fixes #123` to auto-close the issue on merge, or `Refs #123` to link without closing. Cross-repo: `Fixes owner/repo#123`.
- **`Co-authored-by: Name <email>`** for pairing/multi-author; **`Reviewed-by:` / `Acked-by:`** where used.

## Signing & identity (non-negotiable)

- **Every commit is cryptographically signed** — GPG **or** SSH (both earn GitHub's or GitLab's "Verified" badge; do not mandate GPG-only). Configure `commit.gpgsign true`.
- **Before committing, resolve and confirm the identity** per **`procedure-git-identity`**: the committer email, the signing key, and the `Signed-off-by` email must be one consistent identity, and the operator presents it for the user's confirmation before the commit is made. Never commit on `IDENTITY_STATUS=mismatch`, on any state `procedure-git-identity` declares fatal — that skill owns the state list — or on any non-zero exit of `resolve-identity.sh`; **branch on the exit status first, the values second** (its hard failures `die` before any `IDENTITY_*` line is printed, so there is no token to read).

## Atomicity — one self-compilable concern per commit

- **One logical change per commit.** Each commit is a **self-compilable / self-contained unit** — the tree builds and tests pass at every commit, so history stays **bisectable** (`git bisect` is only useful if every commit compiles).
- **Never mix a pure refactor with a behavior change** in one commit — the most common atomicity violation; a reviewer can't tell which lines changed behavior.
- **Cross-cutting work is split into separate per-concern commits**, each a single concern — `feat` / `refactor` / `fix` / `perf` / `chore` / `docs` — in a sensible order (e.g. refactor first, then the feature that builds on it). Use `git add -p` to stage hunks into the right commit when one file spans concerns.
- **Stage only the intended changes** — never `git add -A`/`.`; every staged path must belong to *this* concern. Leave unrelated dirty-tree files (stray build artifacts, another task's work) untouched — the atomic-split rule orders what belongs; this excludes what doesn't.
- Deciding the split is the operator's judgment call: read the diff, group by concern, and produce one clean commit per concern.
- **Lean split — default to the FEWEST commits, each earned.** Start from *one* commit and add a boundary only where a concern genuinely separates (a refactor vs. the feature on top; the product vs. its tooling). Every extra commit must answer "why this, not folded into the previous?" with a named reason — the commit analogue of a review seat earned by a named risk. Do not split for its own sake; a single well-scoped commit is the right answer more often than not.

## The commit-plan gate (MANDATORY — before the identity gate, before any commit)

**Never commit until the user has approved the plan.** After deciding the split, present it and STOP for approval — this is a separate, earlier gate than the identity check (that one confirms *who signs*; this one confirms *what lands and how it reads*).

Present, tersely:
- **How many commits, and the one-line lean rationale** — why this many, not fewer (per Atomicity above). No prose beyond that line.
- **Each commit's full message** — subject + body — in its **own fenced code block** so the user can copy or edit it verbatim. *(This is the deliberate, correct use of a code fence: a message is an artifact to copy, not a report to render.)*

Then ask for approval. The user may approve, edit a message, or change the split. **Apply changes and re-present; commit only on explicit approval.** Do not fold this into a sentence — the messages must be copy-ready blocks.

## Enforcement (make the rules real, not aspirational)
- **Client-side:** a `commit-msg` hook running **commitlint** (`@commitlint/config-conventional`) rejects malformed messages; a `pre-commit` hook running **format + lint + a fast build/test** actually checks the "self-compilable" rule; a **gitleaks** pre-commit hook blocks secrets. *(A signed secret is still a leaked secret — never commit credentials.)*
- **Server-side backstop:** the same checks run as required status checks on protected branches (see `standard-git-branch`); enable GitHub **secret scanning + push protection**, or GitLab's equivalent **secret detection** (blocks a secret *before* it lands — even past a bypassed hook) — client hooks are bypassable with `--no-verify`, so the server is the real guarantee.
- **Repo hygiene:** keep a disciplined `.gitignore` (secrets + build artifacts never staged), a `.gitattributes` (normalize EOL, mark binary/generated files, wire any LFS filters), and route large binaries to **Git LFS** (keeps history diffable and clonable).

## Constraints (NEVER violate)
- Never commit a secret/credential, or a non-self-compilable unit, or a mixed-concern blob that should be split.
- **Never commit unless the user explicitly requested and authorized THIS commit.** The identity gate below answers *who signs*; it never answers *whether to commit*. Absent an explicit request, there is no commit — regardless of how finished the work looks.
- Never commit under an unconfirmed/mismatched identity, or without a signature + `Signed-off-by`.
- Never **bypass a hook** (`--no-verify`/`-n`, stash-around) — a failing hook is the guarantee; STOP and report. Never fall back to `--no-gpg-sign` when signing fails.
- Never commit into a **detached HEAD** or an in-progress rebase/merge/cherry-pick — confirm HEAD is on a branch and no operation is pending first.
- Never pad a subject to hit a length, or write a low-content subject.
- Never rewrite already-published history.

---
*Standard Version: 1.0 — the shared commit rubric. Built to by the git-operator; conventions grounded in Conventional Commits 1.0.0, the DCO, and the Beams/Angular commit canon. Identity resolution lives in procedure-git-identity; branches/PRs/tags in their sibling standards.*
