---
name: standard-jira-artifacts
description: |
  The Jira-specific delta on top of `standard-backlog-artifacts` — the shared rubric the project-manager BUILDS to whenever a Jira issue is authored, updated, transitioned, or audited via `procedure-jira`. Covers ONLY what Jira adds that neither GitHub nor GitLab has an analog for: the markdown-to-ADF authoring surface (`md-to-adf.sh`'s supported flat subset — never Jira wiki notation), Jira's config-driven workflow-STATUS state machine and the readiness-audit-against-status mechanism (auditing a ticket's content against what its CURRENT status requires), and how a confirmed Jira site selects a private per-client overlay skill (`standard-jira-<client>`) through a data-driven site-to-skill registry, never a client name hardcoded here.

  Does NOT restate artifact taxonomy, INVEST, Given/When/Then, DoR/DoD, or the audience matrix — those live in `standard-backlog-artifacts` and apply to Jira artifacts unchanged. Does NOT define any per-client template, label, or status-gate content (that is a `standard-jira-<client>` overlay) or the `procedure-jira`/`procedure-jira-auth` CLI mechanics.
---

# Standard: Jira Artifacts

The **Jira delta only**. This skill adds nothing about what makes a good backlog artifact — that is `standard-backlog-artifacts`, unchanged for Jira. It adds only what Jira, as a tracker, requires that neither GitHub nor GitLab does: an authoring surface (markdown → ADF) and a workflow-status state machine, with a readiness-audit mechanism keyed to that state machine.

## Builds on `standard-backlog-artifacts`

Before writing or auditing any Jira artifact, apply `standard-backlog-artifacts` in full — type taxonomy, INVEST, vertical slicing, Given/When/Then acceptance criteria, Definition of Ready/Done, and the audience matrix all apply to a Jira ticket exactly as they do to a GitHub or GitLab issue. **This skill does not repeat any of that.** A `standard-jira-<client>` overlay may add ticket-template sections and label rules on top; it still specializes the same generic craft, never replaces it.

## Authoring surface: markdown to ADF

Jira stores rich text as Atlassian Document Format (ADF) JSON, not markdown. Every write command that accepts body text — `create --description-file`, `update --description-file` / `--append-file` / `--acceptance-file` / `--review-file`, `comment --text-file` — takes a **markdown file**, converted to ADF by `md-to-adf.sh` before it reaches the API. **Always author in markdown. Never write Jira wiki notation** (`h2.`, `*bold*`, `{code}`) — it is not converted and renders as raw text.

The converter supports a **flat** subset only:

| Markdown | Renders as |
|---|---|
| `## Heading` / `### Heading` | ADF heading, level 2 / 3 |
| `- item` / `* item` (a consecutive run) | One bullet list |
| `1. item` (a consecutive run) | One ordered list |
| `**bold**`, `` `code` ``, `[text](url)` | Inline marks (a link whose scheme isn't http(s)/mailto drops its href, keeps the text) |
| A line that is exactly `---` | A horizontal rule |
| Anything else (tables, fenced code, nested lists) | Degrades to a plain paragraph |

Write flat markdown — a blank line between blocks, no nested lists — so nothing degrades unexpectedly. A `standard-jira-<client>` overlay's ticket template must stay inside this subset.

## Workflow status: the axis neither GitHub nor GitLab has an analog for

A Jira issue carries a **status** from a project- and issue-type-specific workflow graph, configured per project — never a fixed global list. Illustrative default (the shape an unconfigured project effectively behaves like): `Open → In Progress → Reviewing → Done → Closed`. Treat this as an example, not a contract — the real statuses and legal transitions for a given project come from its config, discoverable with `jira.sh workflow <KEY> --confirmed-site SITE`.

Two commands make the status axis usable without guessing:
- **`jira.sh workflow <KEY> --confirmed-site SITE`** — the ticket's current status and the transitions actually available from it right now.
- **`jira.sh transition <KEY> --status TARGET --confirmed-site SITE --plan`** — computes and prints the full path the walk will take (Jira auto-walks through intermediate statuses when there is no direct transition to the target) plus any injected resolution/comment, **without writing anything**. Always run `--plan` before a real transition so a human consent gate discloses the actual path, not just the target.

### The readiness-audit-against-status mechanism

Because status is a real state machine, "is this ticket ready to move?" is answerable as **a checklist keyed by the ticket's current status** — evaluated by fetching it (`jira.sh view <KEY> --confirmed-site SITE --json`) and checking its fields/description against what that status requires. This is the mechanism; the actual table — which sections or fields each status requires — is client-specific and lives in that client's `standard-jira-<client>` overlay. This skill defines the shape, not the content:

1. Determine the ticket's current status from `view --json`.
2. Look up that status's required sections/fields in the client overlay's rules-by-status table.
3. Report each as present-and-adequate, present-but-thin, or missing — never silently pass a thin section.

Neither GitHub nor GitLab issues have an equivalent: there is no per-status "what must be filled in before this moves" concept to audit against.

## Site selects the client overlay (data-driven, never a name switch)

The human-confirmed Jira site — the same `--confirmed-site` every `jira.sh` command requires — selects which `standard-jira-<client>` overlay applies, through a `site → client-skill` registry the private client layer supplies; see `site-registry.example.json` in this directory for the mapping shape. This generic skill, and the flow that orchestrates it, never hardcode a client name. A confirmed site with no registry entry falls back to this generic skill alone, still fully gated.

---
*Standard Version: 1.0 — the Jira delta on the shared backlog-artifact rubric. Built to by the project-manager whenever it operates `procedure-jira`. Builds on `standard-backlog-artifacts` (taxonomy, INVEST, acceptance criteria, DoR/DoD, audience — unchanged for Jira, never restated here). Per-client templates/labels/status-gate content live in a `standard-jira-<client>` overlay; the CLI mechanics live in `procedure-jira` / `procedure-jira-auth`. It does not define the project-manager's conduct, gates, or report envelope (the agent body).*
