---
name: flow-documentation
description: "Orchestrator's procedure for a documentation request — bind only when the user explicitly asks (\"document this\", \"write a README\", \"generate API docs\"). Resolves the AUDIENCE + register before dispatch, delegates to `tech-writer`, runs the deterministic `procedure-doc-lint` gate against the draft, then delegates to the matching `{tech}-reviewer` to fact-check the docs against the code — handling the cross-repo case where the docs and the code being documented live in different repos — looping fixes until approved. Does not define how documentation is written well — that's `tech-writer` + `standard-documentation` — or the lint gate's own checks (`procedure-doc-lint`); this is orchestration only."
---

# Flow: Documentation (on-demand)

The primary agent binds this skill **only when the user explicitly requests documentation** — it is the documentation counterpart of the code developer → review → fix loop. The rest of the time it costs nothing (it is not loaded).

**Trigger phrases:** "Document this" · "Create documentation for…" · "Write README for…" · "Generate API docs" · "Add documentation".

**Documentation types:**

| Type | Description | Output |
|------|-------------|--------|
| **README** | Project/module overview | `README.md` |
| **API Docs** | Endpoint/function documentation | `docs/api/` |
| **Architecture** | System design, diagrams | `docs/architecture/` |
| **Guides** | How-to, tutorials | `docs/guides/` |
| **Runbooks** | Operational procedures | `docs/runbooks/` |

## Step D1 — Resolve the AUDIENCE (MANDATORY — ask, never guess)

A document tuned for an agent, a technical human, a non-technical human, or a business decider is a **materially different document** — this is the same reason `flow-project-management` asks it before drafting a backlog artifact, and documentation has no weaker a claim to it. Ask **before** delegating to `tech-writer`, via one `AskUserQuestion` call:

- **Q1 — Audience** · Header "Audience" · *"Who will read this documentation?"* · options: **Agent** (an LLM system will retrieve/consume it — a product assistant, a support bot, a docs-site agent) · **Human** · **Both** (layered — human-readable prose that also holds up as an isolated retrieved chunk).
- **Q2 — Register** · Header "Register" · *"If a human will read it, what's their relationship to the work?"* · options: **Technical** (an engineer who will build against it) · **Non-technical** (a competent non-engineer executor) · **Business** (a stakeholder who decides/approves).

**If Q1 = Agent, Q2 is moot** — ignore its answer. If Q1 = Both, Q2 supplies the human layer's register.

The audience/register values — `agent` / `human` / `both` and `technical` / `non-technical` / `business` — are the same canonical set `flow-project-management` uses, defined once, externally, in a schema contract: `audience-register.schema.json` (`$HOME/.claude/crucible/contracts/audience-register.schema.json` · framework source: `project-management/contracts/audience-register.schema.json`) — this is deliberately the identical contract, not a re-derived enum, since "who reads this artifact" is the same question whether the artifact is a ticket or a doc; it deploys with every install regardless of which domain(s) are selected (the framework's shared first-run bundle), so citing it from Software Development carries no extra install dependency. Do not invent a separate value set for documentation.

**Why this isn't cosmetic here specifically:** an Agent-or-Both answer is a direct, load-bearing input to `standard-documentation`'s LLM-readability section (self-contained sections, per-section acronym expansion, tables over prose) — for some target audiences, agent-consumability is a **primary** requirement, not a "nice if convenient" afterthought layered on top of human readability. Pass the resolved audience/register to `tech-writer` verbatim in Step D2; do not let it re-derive or guess one.

## Step D2 — Delegate to `tech-writer`

Invoke the `tech-writer` subagent with:
- **What to document** (specific module, API, feature)
- **Documentation type** (README, API docs, guide, etc.)
- **The AUDIENCE + register** resolved at Step D1 — verbatim, never re-derived by the agent
- **File paths** to the implementation being documented — see the cross-repo note below if these files do not live in the same repo as the target docs
- **Target documentation file(s) path**
- **Project context** (tech stack, conventions)

**Check for the target repo's own documentation style guide before assuming the briefed conventions are complete.** Before or alongside the dispatch above, look for a discoverable style/convention file in the target repo (its own `CLAUDE.md`, a `docs/STYLE.md`, a `CONTRIBUTING.md` section on docs, or similar) — do not assume the conventions named in the request are the whole story. The repo's own style file can hold the actual, current documentation pattern while the conventions surfaced by the request alone are stale or reference an already-superseded source. If such a file exists, hand its path to `tech-writer` alongside the other inputs above; if none exists, say so rather than silently proceeding as if the briefed conventions were verified complete.

**Redaction mitigation.** `tech-writer`'s own redaction self-scan (its agent body, step 6) runs an actual `Grep` pattern scan for ticket-ID-shaped identifiers and absolute local filesystem paths, in addition to an LLM judgment pass for person names. **On top of that self-scan, this flow runs a genuinely independent, orchestrator-run mechanical gate — `procedure-doc-lint`'s `doc-lint.sh` — at Step D5, below, before any fact-check or PR step.** `tech-writer` cannot skip or misjudge the pattern-matchable checks, because a party outside the authoring agent verifies them. It does not extend to person-name detection — no regular shape distinguishes a name from an ordinary technical term, so that half relies entirely on `tech-writer`'s own LLM judgment pass.

**Cross-repo documentation (the docs and the documented code live in different repos).** Nothing about `tech-writer`'s toolset (`Read`/`Grep`/`Glob`/`Edit`/`Write`/`WebFetch`/`WebSearch`/`mcp__context7`) can clone, fetch, or otherwise reach a repo that isn't already present on the local filesystem — it reads real files at real paths, nothing more. Before dispatching:
1. **Determine, explicitly, whether the source code and the target docs are in the same repo.** Do not assume same-repo by default — ask if the request doesn't make it obvious (e.g. "document the MCP tools" said from inside a docs repo almost always means the tools live elsewhere).
2. **If cross-repo, you need a local checkout of the SOURCE repo, not just the docs repo.** Confirm its path with the user (a sibling clone, an existing worktree, wherever it lives on this machine) and hand `tech-writer` that path as the "File paths to code" input above — same as any other source path, just outside the docs repo's own tree.
3. **If no local checkout of the source repo exists**, say so plainly rather than proceeding as if it does — ask the user to clone/provide one, or proceed on the explicit understanding that `tech-writer` (and, in Step D6, the reviewer) can only work from whatever is already reachable (e.g. prose the user pastes in, or nothing) and the Verification section will say the code itself was not read.

`tech-writer` builds to its bound `standard-documentation` skill (one Diátaxis mode + one reader + one task; smallest doc that serves the reader). It MUST use `WebFetch`, `WebSearch`, and the `context7` MCP to validate technical accuracy against external sources (see Validation Tools).

## Step D3 — Lock the reference templates (multi-document generation efforts only)

**Applies only when this effort generates multiple similar documents** (e.g. a batch of API-reference pages, a set of per-module guides) — skip this step entirely for a single one-off doc.

1. **Dispatch `tech-writer` for a first, small batch only** — a handful of representative pieces, not the full set.
2. **Before asking for the batch's approval, run this first batch through Step D4 (expose) and Step D5 (lint gate) exactly as any other draft would go through them** — the human approving a batch as the binding template must see its exposed content and know it lints clean first, the same as they would for any single document. Concretely: expose the batch's Documentation Report(s) per Step D4, then run `doc-lint.sh` per Step D5 against every document in the batch, looping fix → re-lint with `tech-writer` (same shape as Step D5's own loop) until every document in the batch lints clean. Only then proceed to point 3 below. This is the ONE case where D4/D5 run ahead of the normal D2→D3→D4→D5→D6 order — for every subsequent, non-template document generated against the locked batch, D4 and D5 run in their normal place, once each, per document.
3. **Get the human's explicit approval of that now-exposed, lint-clean batch** before generating anything further. Do not fold this into the general fix-loop approval at Step D7 — this approval is about the batch becoming a binding template, not about a single document being correct.
4. **Once approved, that batch is the binding reference set** the rest of the effort measures against — `tech-writer`'s subsequent dispatches for the remaining documents must follow its structure, tone, and depth, not improvise a fresh judgment call per document. Hand `tech-writer` the approved batch's file paths alongside the normal Step D2 inputs for every dispatch after this point.
5. If the human requests changes to the approved batch later, treat it as reopening this step — the new approval supersedes the old template before more documents are generated against it.
6. **A defect found in an ALREADY-LOCKED template document — whether a lint violation caught by Step D5, or a reviewer-found defect surfaced later during the normal fact-check/fix loop (Steps D6–D8) — also reopens this step, not just a human-initiated change request.** Fixing a locked template document silently, without the human re-approving it, defeats the point of locking it: every later document was generated against the ORIGINAL approved shape, and a silent fix changes that shape without anyone confirming the new one is still the right template. A Step D5 lint violation is just as capable of changing that shape (e.g. restructuring a flagged single-item list) as a reviewer finding is — so it reopens this step on the identical basis. So: if a fix — from D5's lint gate or from the `{tech}`-reviewer's fix loop — touches one of the batch's locked template documents specifically, treat the fix as reopening this step — get the human's explicit re-approval of the corrected document before treating it as the binding template going forward. **This does NOT apply to a defect in a non-template document** — one generated FROM the locked template, not the template itself. Those follow the normal Steps D5–D8 flow with no re-lock step; only a fix to a template document itself re-triggers this gate.

## Step D4 — Expose the docs summary

Expose the `tech-writer`'s **Documentation Report** as received — it defines the canonical envelope (Type · Reader · Goal · Documents Created/Updated · Summary · Left out/linked · Verification) in its own agent body; **do not restate the fields here.** **Emit as LIVE MARKDOWN — never inside a code fence** (a fence turns a report a human reads into a grey copy-box). You may omit the internal `### Verification` section from the human-facing view. **If Step D2's cross-repo check found no local source-repo checkout available, surface that gap here too** — the reader needs to know a Verification note saying "code not read" isn't a minor caveat, it's the reason to distrust the doc's technical claims until fixed.

## Step D5 — Run the deterministic doc-lint gate (mandatory, before any fact-check)

**Bind `procedure-doc-lint` and run its `doc-lint.sh` script against every document `tech-writer` just
created or updated** — this is the mechanical gate for `standard-documentation`'s Redaction discipline
section. Run it **yourself, from the orchestrator** — never ask `tech-writer` to run it, and never
accept a `tech-writer` report that claims this check already happened. The whole point is that it runs from OUTSIDE the agent that authored the
draft, so a skipped or misjudged self-check can't masquerade as a clean pass.

```
$HOME/.claude/skills/procedure-doc-lint/scripts/doc-lint.sh --file PATH/TO/DOC.md
```

Run it once per document produced at Step D2 (or per document in the locked batch at Step D3). It checks
four deterministic, pattern-matchable things: a bare code fence (no language tag), a ticket/issue-ID-shaped
identifier, an absolute local filesystem path, and a single-item list — full detail in
`procedure-doc-lint`'s own `SKILL.md`.

**On a clean exit (`0`)** for every document, proceed to Step D6.

**On any non-zero exit,** do not proceed to the fact-check step. Report the itemized `file:line`
violations back to `tech-writer` for a fix pass (same fix-loop shape as Step D8's loop below: fix →
re-lint → stop; a 3rd round only if a violation is still open), then re-run `doc-lint.sh` against the
fixed document. Only dispatch Step D6 once every document in scope lints clean.

**Before looping `tech-writer` in on a `TICKET_ID` violation, check whether it's a real false
positive first.** The pattern also matches ordinary technical vocabulary (`UTF-8`, `SHA-256`, an RFC/ISO
number, and similar) — `doc-lint.sh`'s default allowlist already covers the common cases, but a
genuinely domain-specific term the default list doesn't anticipate can still trigger it. If the flagged
text is plainly not a ticket ID, re-run with `--allow-ticket-prefixes <PREFIX>` (see `procedure-doc-lint`)
rather than sending `tech-writer` off to reword correct content. Only loop the fix back to `tech-writer`
for a genuine violation.

**This gate is orthogonal to the fact-check that follows** — `doc-lint.sh` never judges whether the
content is *true*, only whether it is *structurally clean*. A document can lint clean and still fail
Step D6's accuracy review, or vice versa; both gates must pass independently.

**This is not a one-time, first-pass-only check.** Step D8's fix loop re-runs this exact gate against
every revised draft, before the reviewer's re-review — a fix made mid-loop can reintroduce any of these
four violations just as easily as the original draft could.

## Step D6 — Delegate to the `{tech}`-reviewer (fact-check the docs)

The **matching `{tech}`-reviewer** (not a separate docs-reviewer) validates:
- **Implementation accuracy** — does the documentation match the actual code?
- **External reference accuracy** — are versions, APIs, links correct?
- **No hallucinations** — no made-up features or parameters?

**Same-repo (the default case):** the reviewer already has the diff/repo in front of it exactly as any other review dispatch — nothing further to arrange.

**Cross-repo (docs and code live in different repos):** the reviewer's toolset is exactly as local-filesystem-bound as `tech-writer`'s — it cannot fact-check against a repo it can't read. **Hand it the SAME source-repo checkout path used in Step D2**, explicitly, alongside the docs it's fact-checking; do not assume it can discover this itself, since its normal dispatch shape (diff-or-full-audit within one repo) has no field for "the code under discussion lives somewhere else." If that checkout still doesn't exist (Step D2 already flagged this), do not dispatch a fact-check that has nothing to check against — report the gap instead of manufacturing a verdict (see Step D7).

The reviewer MUST use `WebFetch`, `WebSearch`, and the `context7` MCP to cross-reference external documentation.

## Step D7 — Expose the docs-review report

**Emit this as LIVE MARKDOWN — never inside a code fence.** The `>` marks below delimit the spec *here*; they are not part of what you emit. A fence turns a report a human is meant to read into a grey copy-box, and any table inside one renders as raw pipes.

> ## Docs Review Report
>
> **Reviewer:** [tech-reviewer name]
> **Documents:** [count]
> **Source repo:** [same repo | cross-repo — checkout path used, or "unavailable — accuracy unverified" if D2/D6 found none]
>
> ### Verdict: [APPROVED / CHANGES_REQUIRED]
>
> ### Accuracy Check
> | Document | Status | Issue |
> |----------|--------|-------|
> | `README.md` | ✅/❌ | [brief note if any] |
>
> ### Required Fixes
> - [Fix 1]
> - [Fix 2]


## Step D8 — Loop until approved

```
IF reviewer verdict == CHANGES_REQUIRED:
    1. Delegate fixes to tech-writer (include reviewer feedback)
    2. Expose docs fix summary
    3. Re-run Step D5's doc-lint gate against the revised draft — BEFORE the reviewer
       re-reviews. On any non-zero exit, loop the fix straight back to tech-writer
       (same fix -> re-lint shape as Step D5's own first pass) and do not proceed to
       point 4 until the revised draft lints clean. A fix made mid-loop can reintroduce
       a bare fence, a ticket-ID string, a local path, or a single-item list just as
       easily as the original draft could -- this gate is never a one-time-only check.
    4. Delegate re-review to the {tech}-reviewer
    5. Expose docs re-review report
    6. REPEAT until verdict == APPROVED or user intervenes

LOOP POLICY (binds — same as `flow-implementation` §5): fix → verify → stop.
    A 3rd round ONLY if a gating defect is still open — "gating defect" covers BOTH
    an open reviewer-found accuracy defect (point 4) AND a Step D5 lint violation that
    a fix reintroduced or failed to clear (point 3); a persistent lint failure is not
    a separate, uncapped sub-loop, it consumes the SAME round counter as a reviewer
    finding. Exceeding 3 rounds on EITHER kind needs a new approval, not a counter —
    including a document that keeps reintroducing a lint violation on every fix pass.
```

## Validation Tools

Both **tech-writer** and the **{tech}-reviewer** MUST use these to ensure accuracy:

| Tool | Purpose | Use for |
|------|---------|---------|
| `WebFetch` | Fetch specific URLs | Official docs, API references |
| `WebSearch` | Search the web | Latest versions, deprecations |
| `context7` MCP | Query library docs | Framework-specific documentation |

**Accuracy checklist:**
- [ ] Version numbers match official releases
- [ ] API signatures match the actual implementation
- [ ] Links are valid and point to the correct resources
- [ ] No hallucinated features or parameters
- [ ] Code examples are syntactically correct
- [ ] For cross-repo docs: the reviewer fact-checked against a real source-repo checkout, not against the docs author's own prose
