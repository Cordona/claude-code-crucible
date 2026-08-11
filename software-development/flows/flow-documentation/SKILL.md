---
name: flow-documentation
description: "Orchestrator's procedure for a documentation request — bind only when the user explicitly asks (\"document this\", \"write a README\", \"generate API docs\"). Delegates to `docs-writer`, then to the matching `{tech}-reviewer` to fact-check the docs against the code, looping fixes until approved. Does not define how documentation is written well — that's `docs-writer` + `standard-documentation`; this is orchestration only."
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

## Step D1 — Delegate to `docs-writer`

Invoke the `docs-writer` subagent with:
- **What to document** (specific module, API, feature)
- **Documentation type** (README, API docs, guide, etc.)
- **Target audience** (developers, operators, end-users)
- **File paths** to the implementation being documented
- **Target documentation file(s) path** — where the doc should be created/updated
- **Project context** (tech stack, conventions)

`docs-writer` builds to its bound `standard-documentation` skill (one Diátaxis mode + one reader + one task; smallest doc that serves the reader). It MUST use `WebFetch`, `WebSearch`, and the `context7` MCP to validate technical accuracy against external sources (see Validation Tools).

## Step D2 — Expose the docs summary

Expose the `docs-writer`'s **Documentation Report** as received — it defines the canonical envelope (Type · Reader · Goal · Documents Created/Updated · Summary · Left out/linked · Verification) in its own agent body; **do not restate the fields here.** **Emit as LIVE MARKDOWN — never inside a code fence** (a fence turns a report a human reads into a grey copy-box). You may omit the internal `Verification` line from the human-facing view.


## Step D3 — Delegate to the `{tech}`-reviewer (fact-check the docs)

The **matching `{tech}`-reviewer** (not a separate docs-reviewer) validates:
- **Implementation accuracy** — does the documentation match the actual code?
- **External reference accuracy** — are versions, APIs, links correct?
- **No hallucinations** — no made-up features or parameters?

The reviewer MUST use `WebFetch`, `WebSearch`, and the `context7` MCP to cross-reference external documentation.

## Step D4 — Expose the docs-review report

**Emit this as LIVE MARKDOWN — never inside a code fence.** The `>` marks below delimit the spec *here*; they are not part of what you emit. A fence turns a report a human is meant to read into a grey copy-box, and any table inside one renders as raw pipes.

> ## Docs Review Report
>
> **Reviewer:** [tech-reviewer name]
> **Documents:** [count]
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


## Step D5 — Loop until approved

```
IF reviewer verdict == CHANGES_REQUIRED:
    1. Delegate fixes to docs-writer (include reviewer feedback)
    2. Expose docs fix summary
    3. Delegate re-review to the {tech}-reviewer
    4. Expose docs re-review report
    5. REPEAT until verdict == APPROVED or user intervenes

LOOP POLICY (binds — same as `flow-implementation` §5): fix → verify → stop.
    A 3rd round ONLY if a gating accuracy defect is still open. Exceeding it needs
    a new approval, not a counter.
```

## Validation Tools

Both **docs-writer** and the **{tech}-reviewer** MUST use these to ensure accuracy:

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

---
*Procedure Version: 1.0 — the on-demand documentation-request workflow, extracted from the always-resident CLAUDE.md so it loads only when a documentation request fires. How docs are written well lives in docs-writer + standard-documentation; this skill is the orchestration procedure.*
