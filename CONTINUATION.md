# Crucible — Continuation Context

**Purpose:** the pending-work backlog for continuing Crucible's development, each item with enough
context to execute. Read the essentials first.

---

## Essentials — read first (needed to execute *any* task below)

- **Repo layout:** `crucible/` is the repo **root** — README at top level, `deploy/hub/`,
  and the domain folders `software-development/`, `project-management/`, `gtd/`, plus the tiny
  cross-domain `accounts/`. Contracts live per-domain (`{domain}/contracts/`), not at the root.
- **Deploy model:** the Crucible Management Hub (`deploy/hub/hub-install.sh`, invoked as
  `crucible-hub install`) discovers agents (`*.md` with `name:`+`description:` frontmatter),
  skills (dirs with `SKILL.md`), contracts (`*.schema.json`), and the one `CLAUDE.md` **by
  marker**, and symlinks them into `~/.claude`. Runtime data + the deploy target namespace live
  under `~/.claude/crucible/…` regardless of the source repo's name. Run `crucible-hub install`
  without `--apply` first, always — that's the dry run.
- **How work is done — four separate, independently-gated procedures, not one:**
  `flow-implementation` (build → `{tech}`-developer + `{tech}`-reviewer ONLY, never a lens →
  bounded fix loop: round-1 fix, round-2 verify, stop; a 3rd round only on an open CRITICAL/HIGH),
  `flow-review` (the lens swarm, **on-demand only, never automatic** — derives its roster from the
  diff, persists a durable trackable report, runs no fix loop itself), `flow-spec` (cross-repo /
  multi-tech-pair contract, gated before any parallel build), `flow-testing` (tests, last, only on
  the human's explicit confirmation the implementation is right — written by `tests-developer`, never
  the developer). Verdicts: CHANGES_REQUIRED (any open CRITICAL/HIGH) / APPROVED_WITH_FOLLOWUPS
  (only MED/LOW) / APPROVED. `flow-orchestration` is retired — this is not a variant of it, it's
  its replacement.
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
- **A hub redeploy is REQUIRED, not cosmetic, after the `procedure-git-auth` → `procedure-github-auth`
  rename and the new GitLab skills (2026-08-05).** The deployed symlink `~/.claude/skills/procedure-git-auth`
  is now dangling — until `crucible-hub install` runs again, the GitHub account gate is unbindable by
  its new name, and `procedure-gitlab-auth`/`procedure-glab-mr`/`procedure-glab-issues` aren't deployed
  at all. A plain re-install links the new names but does NOT remove the orphaned old link — that needs
  the hub's Uninstall orphan-cleanup path (`List`/`Doctor` will report it as Orphaned).

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

- **On-demand tech pairs** (inbox `20260726T060101Z-fd2f70ff`) — **DONE.** New skill
  `software-development/flows/flow-tech-pair`: polls for language/ecosystem → collision check (inform,
  never decide) → gate → a parallel research swarm (style guide, pitfalls/correctness, linters,
  framework conventions if named) feeds one ephemeral synthesis document → two new meta-authoring
  agents, `software-development/agents/specialists/tech-developer-generator` then `tech-reviewer-generator`, generate the
  pair in sequence against fixed reference templates (`software-development/templates/tech-pair/`, extracted from the
  real Kotlin/Rust/Shell pairs — never deployed, the hub's install script (`deploy/hub/hub-install.sh`)
  excludes anything under `templates/` or `template-`-prefixed, by two independent checks) → a lens review runs BEFORE anything deploys,
  capped at 3 rounds/seat like the tech-pair fix loop → the human chooses whether to deploy. The
  `{tech}`-reviewer's correctness floor is grounded in the research swarm's pitfalls findings, not
  generic advice. Validated end-to-end by generating a real pair: `python-developer`/
  `python-reviewer` + `standard-python`, now deployed — the review pass caught and fixed a real
  security defect (a `bandit -ll` flag that silently excluded Bandit's own LOW-severity
  hardcoded-credential checks) and a real severity miscalibration, not just template conformance.
- **Modular / selective deploy** (inbox `20260726T060057Z-6e67c59c`) — **DONE.** The hub's
  `--domains=CSV`/`--technologies=CSV`/`--pm-backends=CSV` (install) and `--components=CSV`
  (uninstall) selection already covers this — a selected subset, not just whole-framework,
  installs/uninstalls coherently under the marker discovery + required-agent/skill-ref checks.
- **Independent tests-developer pattern** (inbox `20260726T065816Z-2751bc13`) — **DONE**, superseded by
  the `flow-orchestration` retirement itself: `tests-developer` (`software-development/agents/developers/`) is now the
  sole test-writing agent, `build-core` structurally forbids the `{tech}`-developer from touching a
  test file, `review-core` backstops it as a gating violation independent of content, and
  `flow-testing` is the only place tests get written — on the human's explicit confirmation the
  implementation is right, never automatically after a build or a review.
- **Deterministic MD rendering** (inbox `20260725T072634Z-b8ca8251`) — **DONE.** `flow-spec`'s
  (`spec-create.sh`/`spec-approve.sh`/`render-md.sh`) and `flow-review`'s
  (`review-create.sh`/`review-add-round.sh`/`review-update-status.sh`/`render-md.sh`) durable-artifact
  scripts are built, tested, and reviewed, mirroring `flow-inbox`'s `render-md.sh` pattern (JSON
  source of truth + a sole deterministic renderer).

### C. Structural refactors — run a `flow-decision` PANEL first (do NOT decide from the gut)

- **Shell-engine DRY/SRP restructure** (inbox `20260725T115318Z-4f37e4a5`): `jira.sh` is one large
  dispatcher (SRP fail; the re-read/token-cost problem); the gh scripts have ~700 duplicated
  plumbing lines (incl. the path-traversal guard + auth gate, drift risk). Target (agreed):
  dispatcher + engine-core (shared plumbing) + per-command units, for both. The one decision →
  PANEL: relax the "no sourcing between siblings" rule to allow an intra-dir sourced `lib/` (via
  SCRIPT_DIR; cross-skill sourcing still banned)? The token-cost win requires the physical split
  which requires the relaxation. Bank the safe rule-compatible wins first (gh dispatcher
  consolidation + jira move-only reordering); panel the rule-relaxation before the physical jira
  split. Same thread as the reorg above — consider together.
  **GitLab joins this scope (2026-08-05):** the new GL backend (`procedure-glab-*`, mirroring
  `procedure-gh-issues`/`procedure-gh-pr`) is being built monolithic-first, deliberately matching
  gh's current shape rather than SRP/DRY from day one — the panel-gated rule-relaxation above
  isn't worth deciding just for one new backend. When this restructure eventually runs, it covers
  gh + jira + gl together, in one consistent pass, not gl cleaned up alone while gh/jira stay
  monolithic.

### D. Cleanup

(none pending)

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
