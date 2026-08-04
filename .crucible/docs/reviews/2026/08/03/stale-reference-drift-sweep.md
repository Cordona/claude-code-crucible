# Stale-Reference Drift Sweep — Findings & Fix Log

**Date:** 2026-08-03
**Status:** CLOSED, with 3 residual defects disclosed below (independent re-sweep, not fixed in this pass).

**Context:** the earlier domain-folder restructuring (`21dfe9c`, "refactor!: reorganize the framework into domain folders") left a class of stale references behind — paths written for the pre-restructure tree (`roles/`, `operations/agents/`, bare `crucible/`, `templates/tech-pair/`, `deploy.sh`, `main-thread/`) that no longer resolve. A prior sweep caught the `.md`-only subset (see the 2026-08-01 changelog's Round 3 note); this sweep exists specifically to close the gap that one left — non-`.md` files (test/script files, contract JSON) and a few reference categories the earlier pass didn't target at all.

---

## What was searched

Six parallel finders, each covering a distinct category:

1. **Literal old-path grep** — raw string search for the retired path prefixes (`roles/`, `operations/agents/`, `main-thread/`, bare `crucible/`, `templates/tech-pair/` without a domain prefix, `deploy.sh`, `deploy/deploy.sh`).
2. **Cross-reference resolution** — for every path-shaped reference found, does the referenced file/directory actually exist on disk at that path (not just "does the string look plausible").
3. **Conceptual/terminology drift** — retired concepts that may still be described in prose even where no path string is present, e.g. the removed "core tier."
4. **Agent/skill frontmatter specifically** — YAML frontmatter blocks in agent and `SKILL.md` files, checked independently of body prose since frontmatter references (descriptions, bound skills) are load-bearing for discovery/routing.
5. **Test/script files and contract JSON specifically** — the category that slipped through the earlier `.md`-only sweep: `.sh` test/script files and `.schema.json` contract files.
6. **`deploy/hub/`'s own documentation comments** — the untracked hub CLI directory's inline header/doc comments, checked separately since it postdates the restructuring and wasn't covered by any earlier sweep.

Each candidate hit went through adversarial per-file verification before being counted as a genuine finding — confirming the referenced path is actually absent/wrong, not a false match on a substring or a correct reference to something that legitimately still exists under an old-sounding name.

---

## What was found

**27 genuine findings** confirmed, across 12 files (**41 false positives correctly rejected** by the per-file verification pass — mostly legitimate `$id` schema namespace URLs, correctly domain-qualified paths that merely contain a retired word as a substring, and the deploy-target path `~/.claude/crucible/contracts/...`, which is a real, current path and not stale).

| File | Findings |
|---|---|
| `CONTINUATION.md` | 9 |
| `software-development/agents/specialists/tech-developer-generator.md` | 4 |
| `software-development/flows/flow-tech-pair/SKILL.md` | 4 |
| `gtd/flows/flow-inbox/SKILL.md` | 2 |
| `gtd/flows/flow-inbox/tests/run-tests.sh` | 1 |
| `software-development/flows/flow-decision/SKILL.md` | 1 |
| `project-management/agents/project-manager/project-manager.md` | 1 |
| `project-management/agents/project-manager/skills/standard-backlog-artifacts/SKILL.md` | 1 |
| `project-management/flows/flow-project-management/SKILL.md` | 1 |
| `software-development/templates/tech-pair/template-tech-developer.md` | 1 |
| `software-development/templates/tech-pair/template-standard-tech.md` | 1 |
| `software-development/templates/tech-pair/template-tech-reviewer.md` | 1 |

Categories of drift represented: bare `templates/tech-pair/...` missing its `software-development/` domain prefix; `deploy.sh`/`deploy/deploy.sh` referring to a retired single-script deploy model instead of the current `deploy/hub/` CLI; `crucible/contracts/...` used as a "framework source" annotation where the real source is a domain-qualified `contracts/` directory (`crucible/contracts/` is only valid as the *deployed* merge-target path, `$HOME/.claude/crucible/contracts/...`); a stale `operations/agents/gtd-inbox-writer/...` comment path in a test script; and `CONTINUATION.md`'s own accumulated `main-thread/`, `deploy.sh`, and `--only TYPE`-flag references from before the restructuring.

---

## What was fixed

All 27 findings were fixed, across three parallel fix batches (one per finder-derived file group), each closing with a re-read verification against the exact target string and — where a `.sh` file was in scope — an `sh -n` syntax check.

- **`software-development/agents/specialists/tech-developer-generator.md`** — 4 bare `templates/tech-pair/...` references prefixed to `software-development/templates/tech-pair/...`.
- **`software-development/flows/flow-tech-pair/SKILL.md`** — same prefix fix in the frontmatter description, one body reference, and the footer (3 occurrences); plus `deploy/deploy.sh` replaced with the current `deploy/hub/crucible-hub install ...` invocation, including a corrected `--apply`/dry-run example.
- **`software-development/templates/tech-pair/template-tech-developer.md`**, **`template-standard-tech.md`**, **`template-tech-reviewer.md`** — each header comment's `deploy.sh excludes anything template-prefixed...` replaced with a reference to the actual exclusion logic, `deploy/hub/lib/hub-discovery.sh` (verified: that file does contain the `! -name 'template-*'` / `-path .../templates -prune` exclusions the comment describes).
- **`software-development/flows/flow-decision/SKILL.md`**, **`project-management/flows/flow-project-management/SKILL.md`**, **`project-management/agents/project-manager/project-manager.md`**, **`project-management/agents/project-manager/skills/standard-backlog-artifacts/SKILL.md`** — each "framework source: `crucible/contracts/...`" annotation corrected to its real domain-qualified path (`software-development/contracts/...` or `project-management/contracts/...` as applicable). The adjacent deployed-path clause (`$HOME/.claude/crucible/contracts/...`) was left untouched in every case — that half is correct as-is.
- **`gtd/flows/flow-inbox/SKILL.md`** — both occurrences of `crucible/contracts/inbox-entry.schema.json` (frontmatter + footer) corrected to `gtd/contracts/inbox-entry.schema.json`.
- **`gtd/flows/flow-inbox/tests/run-tests.sh`** — a comment path corrected from `operations/agents/gtd-inbox-writer/...` to `gtd/agents/gtd-inbox-writer/...`; `sh -n` clean.
- **`CONTINUATION.md`** — all 9 findings fixed: the `deploy/deploy.sh` reference and the "Deploy model" bullet reworded around `deploy/hub/hub-install.sh`/`crucible-hub install`; the tech-pair DONE item's `deploy.sh excludes...` claim repointed at the hub's install script; the modular/selective-deploy item's stale `--only TYPE` claim replaced with the hub's real `--domains`/`--technologies`/`--pm-backends`/`--components` flags (verified no `--only TYPE` flag exists anywhere in the current hub scripts); two `main-thread skill` references replaced with a cross-cutting-skill description noting `main-thread/` no longer exists post-restructure, with candidate homes named; the source-tree reorg item's `main-thread/neutral` reference replaced the same way.

Each fix-agent report confirmed, by direct re-read, that only the targeted string changed and nothing else in the surrounding text moved.

---

## Deliberately excluded, by design

- **Dated archival records under `.crucible/docs/`** — historical review/spec artifacts are intentionally not rewritten to match current paths; they are a record of what was true when they were written.
- **`SESSION-HANDOFF.md`** — subject to a separate, already-planned deletion; not worth fixing in place.

---

## Final re-sweep result (independent, not the fixer's own claim)

**Verdict: not clean.** An independent re-sweep — run fresh, without relying on the fix agents' own success claims — found **3 genuine remaining stale-reference issues**, none of which fall under either deliberate exclusion above:

1. **`software-development/agents/specialists/tech-reviewer-generator.md` (lines 32, 36)** — bare `templates/tech-pair/template-tech-reviewer.md`, missing the `software-development/` prefix its sibling `tech-developer-generator.md` correctly received in this sweep. Same defect class, just missed on this file.
2. **`software-development/agents/specialists/review-arbiter.md` (lines 74, 84)** and **`software-development/flows/flow-external-review/SKILL.md` (lines 117, 217, 221)** — 5 occurrences of `(framework source: crucible/contracts/*.schema.json)`. There is no top-level `crucible/` directory in the repo; the real framework source for each of these schemas is `software-development/contracts/*.schema.json` — the same "framework source" annotation pattern fixed elsewhere in this sweep, just not on these two files.
3. **`gtd/agents/gtd-inbox-writer/skills/procedure-inbox-capture/tests/run-tests.sh` (line 225)** — `SCHEMA_FILE` is resolved via a `cd` with one `../` too many post-restructure (6 levels up instead of the correct 5), so it silently resolves to `/inbox-entry.schema.json` instead of `gtd/contracts/inbox-entry.schema.json`. The `[ ! -f "$SCHEMA_FILE" ]` guard is always true, so the script's JSON-Schema validation step silently no-ops on every run — no test failure surfaces because the script is designed to fail open. Introduced in the same restructuring commit (`21dfe9c`) this sweep targets.

Confirmed clean by the same re-sweep: every other hit for `roles/`, `operations/`, `main-thread/`, `patterns/*`, and bare `contracts/` outside the two exclusions is either a correct current reference, a legitimate schema `$id` namespace URL, a correct deployed-path mention, or (in `CONTINUATION.md`) historical prose that correctly states the old name no longer exists — not a defect.

**Net result:** 27/30 genuine stale references found by this sweep are fixed and verified; 3 remain open (tracked here, not yet fixed) — 2 are the same "missing domain prefix" / "framework source" defect classes this sweep already fixed elsewhere, just on files the finders didn't cover, and 1 is a live, silently-skipped test-validation bug in `procedure-inbox-capture`'s test suite.
