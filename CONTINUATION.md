# Crucible — Continuation Context

**Purpose:** the pending-work backlog for continuing Crucible's development, each item with enough
context to execute. Read the essentials first.

---

## Essentials — read first (needed to execute *any* task below)

- **Repo layout:** `crucible/` is the repo **root** — README at top level, `deploy/deploy.sh`,
  `operations/`, `main-thread/`, `roles/`, `patterns/`, `contracts/`.
- **Deploy model:** `deploy.sh` discovers agents (`*.md` with `name:`+`description:` frontmatter),
  skills (dirs with `SKILL.md`), contracts (`*.schema.json`), and the one `CLAUDE.md` **by
  marker**, and symlinks them into `~/.claude`. Runtime data + the deploy target namespace live
  under `~/.claude/crucible/…` regardless of the source repo's name. Run `deploy.sh --dry-run`
  first, always.
- **How work is done (flow-orchestration):** for any code change → brief → derive a review roster
  from empty → **gate the plan with the user** → `{tech}`-developer implements → parallel review
  swarm (`{tech}`-reviewer + applicable `lens-*`) → bounded fix loop (round-1 fix gating findings,
  round-2 verify, stop; a 3rd round only on an open CRITICAL/HIGH) → executive summary. Verdicts:
  CHANGES_REQUIRED (any open CRITICAL/HIGH) / APPROVED_WITH_FOLLOWUPS (only MED/LOW) / APPROVED.
- **Commit discipline:** author the message to a file; **expose it verbatim before committing**;
  commit **signed** with your own public identity (never a work/client email).
- **Jira cycle rhythm:** ground-truth probe (read-only) → gate → build + offline mock tests →
  review swarm → fix → **guarded** live test → commit. Live writes are consent-gated; reads are
  free.
- **Guarded live-test safety model:** never mutate a real/non-test artifact. Every mutation target
  must be **run-minted AND carry a `[CRUCIBLE][TEST]` provenance tag** (real artifacts never do),
  verified fail-closed before each call; use explicit `--keys`, never a JQL that could sweep real
  issues.
- **Keep the repo free of any client/employer identifiers** — org-specific work is host-local or a
  separate private skill, never in this shared tree.

---

## Pending work

Each item: **what · where · context/how · constraints.** Inbox ids are noted for traceability.

### A. Issue-scheduling (`cmd_schedule`) residue

- **Proper guarded live-test rig for `schedule`.** Extend `procedure-jira/tests/agile-test-rig.sh`
  with `rig_schedule_*` wrappers (to-sprint / to-backlog / to-epic / from-epic) that assert every
  target (sprint/board/epic/issue) is run-minted + provenance-tagged before calling
  `jira.sh schedule`. The feature was live-proven via a one-off script; make it a durable rig.
  Mirror the existing assert-minted-before-mutation guards.
- **`cmd_sprint --issues` arg-parse quirk** (inbox `20260728T061732Z-d73f2e4d`).
  `jira.sh sprint <id> --issues --confirmed-site <site>` prints USAGE when `--confirmed-site`
  arrives via an unquoted shell var, but the **byte-identical literal argv works** — reproducible,
  clean bytes. Suspected arg-parse ordering bug in `cmd_sprint` (likely also `cmd_epics` /
  `cmd_backlog`) in `procedure-jira/scripts/jira.sh`. Find root cause, fix, add a regression test.
- **LOW review follow-ups on `cmd_schedule`:** (1) `validate_numeric_id` accepts a bare `0`, so
  `--to-sprint 0` / `--board 0` reach the API (fail closed at the server) — optionally add an
  op-local pre-flight reject; (2) pin the method more tightly in the `--jql` move test. Non-gating.

### B. New framework capabilities

- **On-demand tech pairs** (inbox `20260726T060101Z-fd2f70ff`): a skill + subagent that
  **generates a new `{tech}`-developer + `{tech}`-reviewer pair on demand** (e.g. Python, Go). It
  web-researches the language's clean-code/idioms, then authors the agent `.md` artifacts
  following the established patterns of the existing agents (`roles/developers/agents/`,
  `roles/reviewers/agents/tech/`) + the `standard-*` rubrics. The `{tech}`-reviewer must own the
  correctness floor.
- **Modular / selective deploy** (inbox `20260726T060057Z-6e67c59c`): let `deploy.sh` deploy the
  **whole framework OR a selected subset** (some developers/reviewers, or only the GitHub flow, or
  only Jira). `deploy.sh` already has `--only TYPE`; extend to component/profile selection via a
  selection script/manifest. Keep the marker discovery + required-agent/skill-ref checks coherent
  under a partial roster.
- **Independent test-author pattern** (inbox `20260726T065816Z-2751bc13`): a **generic test-writer
  agent, separate from the `{tech}`-developer**, so tests aren't authored by the party motivated to
  make them pass. Design a tech-agnostic `test-author` agent + wire it into flow-orchestration
  (developer builds → test-author writes tests → swarm reviews).
- **Native-task progress pattern** (inbox `20260725T133509Z-28ec3911`): a skill that, on request,
  has the orchestrator use Claude Code's native tasks (`TaskCreate`/`TaskUpdate`) to track work and
  surface **live status**. New `main-thread` skill (or a CLAUDE.md addition) — contract-level, gate
  carefully.
- **Trackable-plan pattern** (inbox `20260725T081715Z-59bfdd95`): introduce the "trackable plan"
  pattern as a new **main-thread skill** — a plan that stays linked to its execution as work
  proceeds.
- **Deterministic MD rendering** (inbox `20260725T072634Z-b8ca8251`): extend the inbox's
  determinism (a script renders user-facing markdown) to other outputs — e.g. **deterministic
  rendering of an orchestration plan**. Mirror `flow-inbox`'s `render-md.sh` (the script is the
  sole renderer; the agent relays its stdout verbatim).
- **PM tracker disambiguation** (inbox `20260725T061121Z-b1ead236`): when a backlog request doesn't
  name Jira vs GitHub, the PM flow should **ask** rather than guess. In `flow-project-management`,
  mirror the existing mandatory audience-ask. Low-token, contained.
- **Deploy dependency check** (inbox `20260727T091344Z-158efc80`): `deploy.sh` should check for
  required dependencies and **gracefully exit** if essential ones are missing. It already has
  `check_deps` for its own utilities; the gap is the framework's **runtime** deps (jq, gh, git,
  curl) — add a runtime-dep check/warning.
- **Agent-description token trim** (inbox `20260728T054725Z-b4185fdb`): Claude Code warns that
  agent descriptions are **over the 15k-token limit (~23k)**. Trim the `{tech}`-developer/reviewer
  + `lens-*` + operational agent frontmatter `description:` fields so the deployed roster fits.
  Constraint: the orchestrator selects the review roster by reading these `description:`s — trim
  without losing the applicability signal each lens declares.
- **Canary GH issue** (inbox `20260725T062356Z-a3495efe`): implement the "canary gh issue" item —
  confirm the specifics with the user before building.

### C. Structural refactors — run a `flow-decision` PANEL first (do NOT decide from the gut)

- **Source-tree ownership reorg** (inbox `20260725T091423Z-30cae486`): directory placement
  currently ASSERTS ownership. Four proposer-plans/orchestrator-executes skills
  (`procedure-git-ops`, `procedure-gh-issues`, `procedure-gh-pr`, `procedure-jira`) file their
  WRITE scripts under the planner agent, but the **orchestrator** executes them. Fork: (a)
  craft-owner (keep under the agent) vs (b) execution-owner (move to main-thread/neutral). Reorg is
  safe/cheap (deploy symlinks by basename; move dir + redeploy re-points the same-named symlink;
  only risk is the move→redeploy dangling window — do it atomically, no mid-flight sessions).
  **Panel it.**
- **Shell-engine DRY/SRP restructure** (inbox `20260725T115318Z-4f37e4a5`): `jira.sh` is one large
  dispatcher (SRP fail; the re-read/token-cost problem); the gh scripts have ~700 duplicated
  plumbing lines (incl. the path-traversal guard + auth gate, drift risk). Target (agreed):
  dispatcher + engine-core (shared plumbing) + per-command units, for both. The one decision →
  PANEL: relax the "no sourcing between siblings" rule to allow an intra-dir sourced `lib/` (via
  SCRIPT_DIR; cross-skill sourcing still banned)? The token-cost win requires the physical split
  which requires the relaxation. Bank the safe rule-compatible wins first (gh dispatcher
  consolidation + jira move-only reordering); panel the rule-relaxation before the physical jira
  split. Same thread as the reorg above — consider together.

### D. Cleanup

- **Retire `standard-git-pr`** — orphaned after PR ownership moved to the `project-manager`. Remove
  it and any dangling references.

---

## Distilled Jira learnings (so no external notes are needed)

- **Project types matter:** team-managed projects (board type `simple`) and company-managed
  (`scrum`/`kanban`) differ. **Epics link via the `parent` field** in team-managed AND modern
  company-managed — `cmd_schedule` uses the REST v3 `parent` PUT (universal), NOT the Agile epic
  endpoint. Sprint/backlog moves use the Agile POST (`sprint/{id}/issue`,
  `backlog/{boardId}/issue`).
- **Other gotchas:** sprint names must be `<30` chars; `POST /version` uses `project`=KEY (not
  projectId); pagination varies (epic-list has `isLast` but no `total`; issue-lists have `total`
  but no `isLast`); attachments = multipart `-F` + `X-Atlassian-Token: no-check`; inline media =
  upload → follow 303 → extract media UUID → ADF `mediaSingle` with `collection:""`.
- **Engine security invariants (keep):** token off argv (`curl -K` 600 config), host pinned to the
  confirmed site, static jq bodies (`--arg`/`--argjson`, never concatenation), JQL via the escaped
  allow-listed path, all ids/keys validated (`validate_numeric_id`, `validate_ticket_key`) before
  reaching a URL or body.
