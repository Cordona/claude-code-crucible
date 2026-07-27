---
name: flow-project-management
description: The orchestrator's on-demand procedure for a BACKLOG / PROJECT-MANAGEMENT request — the steps the primary agent runs when the user asks to file/write/structure a ticket, story, epic, bug, or spike, or to comment on / edit / close an existing tracked issue. Bind this skill when such a request fires ("file an issue", "write a ticket", "carve an epic", "open a bug", "break this into tickets", "comment on / update / close issue #N"). It owns: asking the AUDIENCE + register (the one input only the user knows), delegating to the project-manager subagent, exposing its draft + recommended structure, and CONSENT-GATING every live tracker write (the orchestrator executes the write only on the user's explicit in-turn approval). It does NOT define how a good artifact is written (that is the project-manager agent + the standard-backlog-artifacts rubric) or the gh mechanics (procedure-gh-issues / procedure-gh-pr) or the account gate (procedure-git-auth); it defines the orchestration procedure only.
---

# Flow: Project Management (on-demand)

The primary agent binds this skill **only when a backlog / project-management request fires** — the ticketing counterpart of the developer → review → fix loop. The rest of the time it costs nothing (it is not loaded). Its whole reason to exist is that a good backlog artifact is a *different artifact per reader*, and only the user knows the reader — so the orchestrator must **ask**, not guess.

**Trigger phrases:** "File an issue / write a ticket" · "Open a bug" · "Create a story / carve an epic" · "Break this down into tickets" · "Comment on / update / edit / close issue #N" · "Add labels / a project to this issue" · "Open / update a pull request".

**What this skill owns vs. what it doesn't:**
- **Owns (here):** the ask, the delegation, exposure, and the consent gate on outward writes.
- **Craft** (type/structure recommendation, INVEST, the audience matrix) → the `project-manager` agent + `standard-backlog-artifacts` (+ the Jira delta `standard-jira-artifacts`).
- **Mechanics** → for **GitHub**: `procedure-gh-issues` (issues) / `procedure-gh-pr` (pull requests), **account gate** `procedure-git-auth`. For **Jira**: `procedure-jira` (the `jira.sh` engine), **site+account gate** `procedure-jira-auth`.

**Tracker selection (before P2).** Pick the tracker from the request, don't ask a separate question: **Jira** when it names Jira or a Jira site/ticket ("file a Jira ticket", "an ONW ticket", "in `<site>.atlassian.net`", a `PROJ-123` key); **GitHub** when it names an issue/PR or a GitHub repo ("file an issue", "a GitHub issue", "open a PR"). When genuinely ambiguous, ask which tracker — this is the one selection the flow makes; everything below is the same shape for both, differing only in which mechanics/gate skills apply. **The flow NEVER names a client** — for Jira, the confirmed *site* selects the private client overlay, data-driven (see P2).

---

## Step P1 — Resolve the audience (MANDATORY — ask, never guess)

A backlog artifact tuned for an agent, a technical human, a non-technical human, or a business decider is a **materially different artifact**. **This ask applies to artifact-AUTHORING requests** (create / comment / edit — anything that writes text a reader consumes). **Skip P1 for a content-less lifecycle op** — a bare close, adding an existing label / a project, or a Jira **`transition`** (a status walk authors no text) — where no text is authored, **and for a pull request** (a PR has a fixed audience — technical-human reviewers — see the project-manager's Pull requests section): go straight to P2. For an authoring request, the audience is the one input only the user holds — so **ask it before delegating**, via `AskUserQuestion`, as TWO questions in one call:

- **Q1 — Audience** · Header "Audience" · *"Who will read/act on this artifact?"* · options: **Agent** (another AI will pick it up) · **Human** · **Both** (layered).
- **Q2 — Register** · Header "Register" · *"If a human will read it, what's their relationship to the work?"* · options: **Technical** (an engineer who will build it) · **Non-technical** (a competent non-engineer executor) · **Business** (a stakeholder who decides/approves).

**If Q1 = Agent, Q2 is moot** — ignore its answer. If Q1 = Both, Q2 supplies the human layer's register.

The audience/register values — `agent` / `human` / `both` and `technical` / `non-technical` / `business` — are the canonical set defined once in `audience-register.schema.json` (`$HOME/.claude/crucible/contracts/audience-register.schema.json` · framework source: `crucible/contracts/audience-register.schema.json`) — the single source of truth. (The Title-Case `Agent` / `Human` / `Both` above are the Q1/Q2 display labels.)

**Do NOT ask the artifact TYPE** (issue / story / epic / bug / spike) — that is the project-manager's *recommendation*, not a user input. The user can override it after seeing the draft.

**Also settle, before delegating** (ask only if not already clear from the request): the **target repo**, and whether this is **draft-only** (author + report) or **draft-then-create** (author, then create on your later explicit approval). Default to **draft-only** when unsure — creating is the outward, hard-to-retract step.

---

## Step P2 — Delegate to `project-manager`

Invoke the `project-manager` subagent with everything it needs (it has NO conversation history):
- **The raw request / work to capture** (problem, outcome, any context).
- **The AUDIENCE + register** from P1 — verbatim; this is the required input.
- **The target repo** + any conventions (labels, milestone, project, ticket-id scheme).
- **Draft-only vs. draft-then-create**, and on a re-run the **prior artifact IDs** so it updates rather than duplicates.
- For a lifecycle op (comment / edit / close), the **issue number(s)** and what to change.

One artifact-set per delegation. The agent recommends the type/structure, authors each artifact to the audience, and — per its own gates — **drafts and STOPS**; it does not perform a live write off a relayed instruction.

**For Jira**, tell the agent the target is Jira and the **site** (if the request named one): it drafts to `standard-jira-artifacts` (the Jira delta — markdown→ADF surface, workflow-status semantics) on top of `standard-backlog-artifacts`, tuned further by whichever private `standard-jira-<client>` overlay the **confirmed site** selects through the site→skill registry — **data-driven; this flow never names a client**, and a site with no registry entry falls back to the generic conventions, still fully gated. The site is *confirmed* at P5's gate; if it isn't settled yet, the agent drafts to the generic Jira conventions and the overlay is applied once the site is confirmed.

---

## Step P3 — Expose the agent's report

**Emit as LIVE MARKDOWN the terminal renders — never inside a code fence** (a fence turns a report a human must read into a grey copy-box). Present the agent's **Backlog Artifact Report** as received: the audience, the **recommended structure** (and why), each drafted artifact, the decomposition rationale, and the exact `procedure-gh-issues` / `procedure-gh-pr` script invocation(s) it proposes. Surface any open question the agent refused to guess on.

---

## Step P4 — The creation gate (MANDATORY — before ANY live tracker write)

**Authoring is free; writing to a live tracker is not.** A created/edited/closed issue fires notifications, lands on someone's board, and is hard to retract — the same class as a commit. So no outward write happens without the user's **explicit approval of THIS write, in their own turn**. Present what will happen and wait:

- **Per write, not per session** — approval of one create is not approval to also close, comment, or edit.
- **Approval of the draft *wording* is not "create it."** Ask the outward question explicitly.
- **Surface the irreversible specifics** so the user is consenting to the real effect:
  - **Create-missing-labels** (`ensure-labels.sh`) — **list exactly which labels it will create**; these are persistent repo labels everyone will see.
  - **Edit** (`update-issue.sh`) — a body edit is a **replacement, not an append**; show the FULL new body and note it overwrites the current one.
  - **Close** — confirm the issue number + reason.
  - **Open a PR** (`create-pr.sh`) — it **requests reviews + notifies**; confirm head/base and that a duplicate isn't already open. **Edit a PR** (`update-pr.sh`) — the body is a **replacement**; show the full new body.
  - **Jira create / comment / update** (`jira.sh create|comment|update`) — confirm the **site** + project/issue; a Jira `update --description-file` **replaces** the description (`--append-file` appends); `update --labels` **replaces the whole label array**.
  - **Jira transition** (`jira.sh transition`) — Jira **auto-walks** intermediate statuses, so the effect is more than the named target, and disclosing it needs a **live read**. A transition is the **one** op whose consent-disclosure itself needs the resolved credential, so **its site+account gate runs BEFORE this P4 disclosure — not at P5**. Sequence it cleanly:
    1. **Clear the site+account gate first** — run `procedure-jira-auth`'s gate now (present + confirm the active **site + account** using its fixed site+account report template, then `export JIRA_CURL_CONFIG=<jira-curl-config.sh --site <confirmed-host>>`). This is P5 step 1's procedure pulled ahead, because the disclosure below cannot run without it.
    2. **Disclose the actual path** — run `jira.sh transition <KEY> --status TARGET --confirmed-site <host> --plan` (it writes nothing — **one read call**, which is exactly why it needs the confirmed site + `$JIRA_CURL_CONFIG` already in hand from step 1) and show its output — the full walked path plus any injected resolution/comment — so the user consents to the real walk, not just the target.
    3. **Then take P4 consent** (below). P5 re-invokes the SAME command **without** `--plan` to execute, and does **not** re-run the gate (already cleared this turn).
- **Draft-only** dispatches never reach this gate for a write — you report the draft and the proposed invocations, and stop.

**Collect the consent via `AskUserQuestion`** — the same structured gate used for git commits (`flow-git-operations` G4, CLAUDE.md §8) and the orchestration plan (`flow-orchestration` §3). The full drafted body stays in P3's live-markdown reveal *above* the question; the question captures the write + its scope:
- Header **"Write"** · question *"Approve this tracker write? (draft shown above)"*
- Options, each **naming the exact target**: e.g. **"Approve — create the issue in `owner/repo`"** · **"Approve — open the PR (`head` → `base`)"** · **"Approve — create the Jira ticket in `PROJ` on `<site>`"** · **"Approve — transition `PROJ-123` (path shown above)"** · **"Approve — save as draft only"** (no write) · **"Request changes"** → loop to P2. `ensure-labels.sh` (persistent repo labels) gets its OWN option/question even when bundled with a create. `AskUserQuestion`'s built-in **"Other"** captures a free-text change.

Only the selected option authorizes P5; **"Request changes" / "Other" loops back to P2**, never to a write.

---

## Step P5 — Execute the write (only on P4 consent) — the orchestrator writes

Once the user has explicitly approved a specific write in their own turn, **you (the orchestrator) execute it** — the project-manager *proposed*; you *write*. This mirrors the git side in `flow-git-operations` (CLAUDE.md §8, G5): a subagent cannot verify that a relayed approval is genuine consent, so it never writes off a relay; the participant who holds the user's authorization does. **Never route the approved write back to the project-manager** — it will (correctly) refuse a relayed instruction, and you would deadlock. The `procedure-gh-issues` / `procedure-gh-pr` / `procedure-git-auth` and `procedure-jira` / `procedure-jira-auth` scripts are deployed globally, so you invoke them **directly by their deployed absolute path** — you need not be their bound owner.

The steps below are the **GitHub** path; the **Jira** path is its mirror image and follows immediately after.

1. **Account gate first, before any write** — follow `procedure-git-auth`: run `$HOME/.claude/skills/procedure-git-auth/scripts/gh-auth-status.sh`, present the active account, and get the user's confirmation it is the correct login. One confirmation covers a batch of writes in the *same* turn; re-affirm if the active account could have changed. (Read-only `find-duplicate.sh` needs only that `gh` is authenticated, not the confirmation.)
2. **Materialize the body yourself — the agent only *previewed* it.** For any create / comment / body-edit, `Write` the approved artifact body (as exposed in P3) to a **private temp file via `mktemp` under the system temp dir — never inside the repo/source tree** — and remove it once the script has consumed it. Do NOT reuse the agent's proposed `--body-file` path; it was a preview and was never created. Never hand-author a `gh` command or heredoc.
3. **Run ONLY the specific write(s) the user approved in P4** — not the whole proposed set. `ensure-labels.sh` (which creates **persistent repo labels**) needs its OWN approval even when bundled with a create. For a create, run `find-duplicate.sh` first (dedup). Match each script to its flag: bodies via `--body-file`; a **closing comment via `close-issue.sh --comment-file`** (not `--body-file`). Invoke by deployed path, e.g. `$HOME/.claude/skills/procedure-gh-issues/scripts/create-issue.sh … --body-file <temp file>`. For a **pull request**, use `procedure-gh-pr`: `find-pr.sh --repo … --head <branch>` first (dedup), then `create-pr.sh --repo … --head … --base … --title "…" --body-file <temp file> [--draft]` (refuses a duplicate) or `update-pr.sh --repo … --pr N [--body-file <temp file>] …` (body replaced only if `--body-file` is given) — same deployed-path + `--body-file` discipline; the PR title is an argv token.
4. **Report** what landed (type · number · URL) from the scripts' actual `PM_*` output — never a fabricated status.

### The Jira write path (the mirror of the above — the site+account gate replaces the gh account gate)

For a **Jira** write, the same "orchestrator executes, agent only proposed" rule holds; only the gate and the mechanics differ (`procedure-jira-auth` + `procedure-jira` in place of `procedure-git-auth` + `procedure-gh-*`):

1. **Site + account gate first — the Jira analog of the gh account gate** (`procedure-jira-auth`'s wrong-instance guard). Run `$HOME/.claude/skills/procedure-jira-auth/scripts/jira-auth-status.sh [--site <site from the request>]`, **present the active site + account using `procedure-jira-auth`'s fixed site+account report template** (filled verbatim from the script's `JIRA_AUTH_*` output — the deterministic analog of the gh account-report block), and get the user's **explicit confirmation** it is the correct site *and* login — never assume the default site; a user holds several at once, and one client's ticket must not land on another's Jira. If wrong, the user switches the default (`jira-accounts.sh set-default --site …`) or sets up a credential interactively (`jira-login.sh`); re-run status and re-confirm. Then resolve the credential handoff: run `$HOME/.claude/skills/procedure-jira-auth/scripts/jira-curl-config.sh --site <confirmed-host>` and **`export JIRA_CURL_CONFIG=<its printed path>`** (a path, never the token). This confirmed host is also the `--confirmed-site` value below — the same string. **For a `transition` this gate already ran before P4** (its `--plan` disclosure required it) — do NOT re-run or re-confirm it here; reuse the confirmed host + exported `JIRA_CURL_CONFIG` from that pre-P4 step.
2. **Materialize any body yourself — the agent only *previewed* it.** For a create/comment/update body, `Write` the approved markdown (as exposed in P3) to a **private `mktemp` file under the system temp dir — never inside the repo/source tree** — and remove it after the script consumes it, exactly the `--body-file` discipline above. Jira body text is ALWAYS a file (`--description-file` / `--append-file` / `--acceptance-file` / `--review-file` / `--text-file`), never an inline string; `jira.sh` converts the markdown to ADF.
3. **Run ONLY the specific write(s) the user approved in P4**, invoking `jira.sh <cmd> --confirmed-site <host>` by deployed path with `JIRA_CURL_CONFIG` exported. **For a create, run `$HOME/.claude/skills/procedure-jira/scripts/jira.sh search --confirmed-site <host> …` first (dedup)** — the Jira mirror of GitHub's `find-duplicate.sh`; it is read-only and needs the confirmed site but not the confirm step. Then run the approved write — e.g. `jira.sh create --project PROJ --title "…" --confirmed-site <host> --description-file <temp file>`; `comment <KEY> --text-file <temp file> --confirmed-site <host>`; `update <KEY> --confirmed-site <host> [--description-file <temp file> | --append-file <temp file>] …`. For a **`transition`**, the site+account gate + the `--plan` disclosure already ran **before** P4 (see the transition note in P4); now re-invoke the SAME command **without** `--plan` to execute the real walk — do NOT re-run the gate.
4. **Report** what landed from the scripts' actual `JIRA_*` output (`JIRA_ISSUE_KEY` / `JIRA_ISSUE_URL`, `JIRA_COMMENT_ID`, `JIRA_TRANSITIONED_TO`, `JIRA_UPDATED`) — never a fabricated status.

If the user asked to **revise** the draft instead of creating, loop back to P2 with the change; re-expose (P3); re-gate (P4). Match ceremony to stakes — a one-line bug is one question, not a ritual.

---

## Termination

This flow does not auto-continue. When the user's request is drafted (draft-only) or the approved writes have landed, **stop**. A later "now also close it" or "file another" is a **new invocation** of this flow, with its own P1–P5 — never an automatic next step.

---

## Invariants (NEVER break)

- **Ask the audience for an authoring request — never guess it** (P1); content-less lifecycle ops (bare close, adding an existing label / a project, a Jira `transition`) and pull requests (fixed audience) skip the ask. A missing audience on an authoring request is a question to the user, not a default.
- **No live tracker write without the user's explicit, in-turn approval of THAT write** (P4). Relayed or wording-approval is not consent.
- **Pick the tracker (gh vs Jira) from the request, not a separate question** (Tracker selection); ask only on genuine ambiguity. **The flow never names a client** — the confirmed Jira *site* selects the private overlay, data-driven.
- **A Jira write clears the site+account gate first** (`procedure-jira-auth`): present the active **site + account** via its fixed report template, get explicit confirmation, export `JIRA_CURL_CONFIG` from `jira-curl-config.sh`, and pass the confirmed host to `--confirmed-site` — never assume the default site. **The gate's position depends on the op:** for **create / comment / update** it sits at **P5** (their only network call is the write); for a **`transition`** it runs **before the P4 `--plan` disclosure**, because that disclosure makes a live read call and so needs the resolved credential already in hand — P5 then executes the walk without re-running the gate. **A `transition` discloses its auto-walked path via `--plan` before consent** (P4), on the credential that pre-P4 gate resolved. No collision: the gate always precedes the credential-dependent step, whichever step that is.
- **The orchestrator executes the write; the agent only proposes** (P5) — so the agent's relayed-consent doctrine never deadlocks.
- **Surface the irreversible specifics** before consent — which labels, body-replacement, close (P4).
- **Never fabricate** an issue number, URL, or "created" status — report only what a script returned.
- **The artifact TYPE is the agent's recommendation, not a user question** (P1); the AUDIENCE is a user input, not the agent's guess.
- **Draft-only by default** when create-vs-draft is unclear (P1).

---
*Procedure Version: 1.3 — the on-demand backlog/project-management workflow, loaded only when a ticketing request fires. Added the Jira tracker path alongside GitHub: request-driven tracker selection (gh vs Jira, never naming a client), P2 drafting to standard-jira-artifacts + the site-selected client overlay, and a P5 Jira write path gated by procedure-jira-auth's site+account confirm + the `$JIRA_CURL_CONFIG` handoff, with a `transition`'s auto-walk disclosed at P4 via `jira.sh transition --plan`. 1.3 fixes the transition gate ordering: because `--plan` makes a live read call, a transition's site+account gate + `$JIRA_CURL_CONFIG` handoff now runs BEFORE the P4 disclosure (not at P5), while create/comment/update keep their gate at P5; the two site-gate invariants are reconciled so they no longer collide, `transition` joins the P1 audience-skip set, and the Jira create dedup (`jira.sh search`) is promoted to an explicit step parallel to GitHub's `find-duplicate.sh`. The P4 write-consent is collected via a structured `AskUserQuestion` gate (uniform with `flow-git-operations` G4), the artifact shown verbatim above it. Craft lives in the project-manager agent + standard-backlog-artifacts (+ the Jira delta standard-jira-artifacts); gh mechanics in procedure-gh-issues / procedure-gh-pr (account gate procedure-git-auth); Jira mechanics in procedure-jira (site+account gate procedure-jira-auth). This skill is the orchestration procedure only.*
