---
name: standard-jira-artifacts
description: "The Jira-specific delta on top of `standard-backlog-artifacts` — bind whenever a Jira issue is authored, updated, transitioned, or audited via `procedure-jira`. Covers only what Jira adds: markdown-to-ADF authoring, the workflow-status state machine and its readiness-audit mechanism, and how a confirmed site selects a client overlay. Does not restate artifact craft/taxonomy (that's `standard-backlog-artifacts`), define per-client template/label/status content (a `standard-jira-<client>` overlay), or cover the `procedure-jira`/`procedure-jira-auth` CLI mechanics."
---

# Standard: Jira Artifacts

The **Jira delta only**. This skill adds nothing about what makes a good backlog artifact — that is `standard-backlog-artifacts`, unchanged for Jira. It adds only what Jira, as a tracker, requires that neither GitHub nor GitLab does: an authoring surface (markdown → ADF) and a workflow-status state machine, with a readiness-audit mechanism keyed to that state machine.

## Builds on `standard-backlog-artifacts`

Before writing or auditing any Jira artifact, apply `standard-backlog-artifacts` in full — type taxonomy, INVEST, vertical slicing, Given/When/Then acceptance criteria, Definition of Ready/Done, and the audience matrix all apply to a Jira ticket exactly as they do to a GitHub or GitLab issue. **This skill does not repeat any of that.** A `standard-jira-<client>` overlay may add ticket-template sections and label rules on top; it still specializes the same generic craft, never replaces it.

## Authoring surface: markdown to ADF

Jira stores rich text as Atlassian Document Format (ADF) JSON, not markdown. Every write command that accepts body text — `create --description-file`, `update --description-file` / `--append-file` / `--acceptance-file` / `--review-file`, `comment --text-file`, `comment-edit --text-file` — takes a **markdown file**, converted to ADF by `md-to-adf.sh` before it reaches the API. **Always author in markdown. Never write Jira wiki notation** (`h2.`, `*bold*`, `{code}`) — it is not converted and renders as raw text.

The converter supports a defined subset of markdown:

| Markdown | Renders as |
|---|---|
| `## Heading` / `### Heading` | ADF heading, level 2 / 3 |
| `- item` / `* item` (a consecutive run) | One bullet list |
| `1. item` (a consecutive run) | One ordered list |
| An indented `- item` under a list item | A **real nested list** — the deeper list becomes a child of its parent list item, not a flattened or degraded block |
| `- [ ] item` / `- [x] item` (a consecutive run) | One **native Jira task list** — real checkboxes a reader can tick, not a decorated bullet (`[x]`/`[X]` = done) |
| A GFM pipe table (header row + `\|---\|---\|` separator + body rows) | An ADF table |
| A triple-backtick fenced block (optionally with a language tag) | An ADF code block |
| `**bold**`, `` `code` ``, `[text](url)` | Inline marks (a link whose scheme isn't http(s)/mailto drops its href, keeps the text) |
| `[~accountId:<ID>]` | A real Jira **@mention** (the user is notified). **Write it BARE** — wrapping it in `**`/`*`/`_` suppresses the mention (it renders as literal text), and `~~` leaves stray tildes around it; marks do not nest here, exactly as for a wrapped `[text](url)` link. `<ID>` must be an **accountId**, never a name or email: the converter performs no lookup, so an **out-of-shape** id (wrong characters, over 128 chars) degrades to literal text, while a well-shaped but **wrong** id is sent through as a real mention unchanged — the converter cannot know it is wrong, only Jira can reject it. Get one from a `view --json`/`search --json` payload, or from the account the auth gate already confirmed. |
| A line that is exactly `---` | A horizontal rule |
| Anything the converter doesn't recognize (footnotes, raw HTML, definition lists, …) | Degrades to a plain paragraph |

The subset is wider than the table above (blockquotes, `> [!NOTE]`-style panels, `_italic_`, `~~strike~~`, hard breaks, headings 1 and 4–6 all convert too); `md-to-adf.sh`'s own header comment is the authoritative list. **As a matter of style, prefer flat markdown** — a blank line between blocks, shallow nesting — because a Jira ticket read in a narrow side panel is easier to scan that way, not because deeper structure fails to convert. A `standard-jira-<client>` overlay's ticket template must stay inside this subset.

**Task-list caveat:** a plain bullet cannot live inside a task list (ADF's `taskItem` holds inline text only), so an indented `- plain item` under a checkbox **closes the task list** and lands as a sibling block instead of a nested one — the content survives, the nesting does not. Keep a checklist to checkboxes only.

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
*Standard Version: 1.1 — `md-to-adf.sh` gained `[~accountId:<ID>]` → a real ADF `mention` node (previously the syntax passed through as literal text, so every attempted @mention silently failed to notify anyone), and `procedure-jira` gained a `comment-edit` command. Added the mention row to the supported-markdown table — with the accountId-not-a-name constraint, since the converter performs no lookup and never makes a network call — and named `comment-edit --text-file` alongside `comment --text-file` in the body-text command list.*
*Standard Version: 1.0 — the Jira delta on the shared backlog-artifact rubric. Built to by the project-manager whenever it operates `procedure-jira`. Builds on `standard-backlog-artifacts` (taxonomy, INVEST, acceptance criteria, DoR/DoD, audience — unchanged for Jira, never restated here). Per-client templates/labels/status-gate content live in a `standard-jira-<client>` overlay; the CLI mechanics live in `procedure-jira` / `procedure-jira-auth`. It does not define the project-manager's conduct, gates, or report envelope (the agent body).*
