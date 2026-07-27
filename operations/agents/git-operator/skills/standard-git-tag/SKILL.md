---
name: standard-git-tag
description: The single definition of a good release TAG and versioning — the shared rubric the git-operator follows when tagging a release. Applies whenever a release is cut. Covers annotated + signed tags, SemVer-named tags, the Conventional-Commits→SemVer contract, changelog discipline, and release automation options. It does NOT define commit format (standard-git-commit), branches (standard-git-branch), PR policy (standard-git-pr), or how the signing identity is resolved (procedure-git-identity — bound alongside this for signing).
---

# Standard: Git Tag & Versioning

The **one** definition of a good release tag. Releases are cut from **tags**, so the tag — not any commit — is the durable, signed anchor of a release (a rebase- or squash-merge can leave the tag as the only signed release marker).

## The tag

- **Annotated + signed.** `git tag -s vX.Y.Z -m "…"` — an annotated tag object carries tagger/date/message and is signed (same backend as commit signing via `gpg.format` — GPG or SSH). Verify with `git tag -v vX.Y.Z` before publishing. Set `tag.gpgsign true` so signing is automatic.
- **Never a lightweight tag for a release** — lightweight tags carry no metadata or signature.
- **SemVer name** — `vMAJOR.MINOR.PATCH` (e.g. `v2.4.1`).

## Versioning — Conventional Commits → SemVer

Public versions follow **Semantic Versioning 2.0.0**, derived from the commit history:
- `fix:` → **PATCH**
- `feat:` → **MINOR**
- any **`BREAKING CHANGE:` / `!`** (regardless of type) → **MAJOR**

A **released version is immutable** — never re-cut or move a published version tag.

## Changelog

Maintain human-facing release notes (never a raw `git log` dump):
- **Keep a Changelog** format — grouped **Added / Changed / Deprecated / Removed / Fixed / Security**, newest-first, with an `Unreleased` section — either hand-maintained, or
- **Generated** from the Conventional-Commit history. Pick **one** lane (don't hand-maintain *and* generate — they conflict).

## Release automation (optional)

The payoff of the commit conventions. Choose per appetite:
- **release-please** (PR-gated) — accrues changes in a Release PR; on merge it bumps SemVer, updates the changelog, and cuts the tag + GitHub Release. A human still merges the PR — the **culturally-consistent default** for this human-gated, ticket-driven standard.
- **semantic-release** (zero-gate) — fully automatic on merge to the release branch, including publish. Reach for it only if you want hands-off continuous publishing.

## Release prep — the optimized build runs HERE, once

**Before cutting the tag, run the project's optimized/production build** — `cargo build --release`, `npm run build`, or the language's equivalent — and STOP if it fails. This is deliberately *not* a per-change developer gate (`build-core`): the optimized profile catches a narrow, real class of defect that the debug/dev build cannot — integer overflow **wraps** instead of panicking, optimization can expose UB in unsafe code, and bundlers only fail at production build time. That is worth one run at the release boundary and not ~50 s on every implementation round.

The tag is the right owner because it is the moment the artifact becomes public and immutable. A release-prep gate attached to nothing is a gate nobody runs — and a check that never executes is worse than no check, because it reads as coverage.

## Constraints (NEVER violate)
- **Never cut or publish a release tag unless the user EXPLICITLY requested and authorized THIS tag** — the version, in this conversation. A tag is the most irreversible artifact here: it is published, immutable, and never re-cut (below), and it is what downstream consumers pin. Approval to commit, to push, or to "do the release" is not approval of *this version at this SHA*. Present the version + target SHA and wait. If you are unsure whether they asked: they did not.
- Never publish a release from a lightweight or unsigned tag.
- Never move or re-cut a published version tag.
- Never bump the version by hand in a way that contradicts the commit history's SemVer signal.

---
*Standard Version: 1.0 — the shared tag/versioning rubric. Followed by the git-operator. Grounded in SemVer 2.0.0, Keep a Changelog, and Conventional Commits. Signing identity lives in procedure-git-identity.*
