# Crucible

**Crucible turns Claude Code from a single implementer into an orchestrated team.**

Out of the box, one agent writes the code, reviews its own work, and decides on its own when
to commit. It is its own reviewer and its own gatekeeper. Crucible breaks that up: the primary
agent becomes an **orchestrator** that reads a contract (`CLAUDE.md`), assembles a roster of
specialized subagents — developers, an independent review swarm, operational agents — and drives
a **gated build → review → fix loop**. Work is implemented by one agent, judged by others, and
every outward or destructive act (a commit, a push, a ticket, a live tracker write) waits on
explicit human consent. Where determinism matters, **scripts own every byte written** and the
agents only decide which script to run.

The result is separation of concerns applied to an AI coding workflow: the thing that does the
work is never the only thing that checks it, and nothing irreversible happens without a human in
the loop.

---

## Table of Contents

- [What is Crucible](#what-is-crucible)
- [At a glance](#at-a-glance)
- [How it works](#how-it-works)
- [Deploying](#deploying)
  - [Human setup](#human-setup)
  - [Agentic setup](#agentic-setup)
- [Reference](#reference)
  - [Entry modes](#entry-modes)
  - [Developers](#developers)
  - [Reviewers](#reviewers)
  - [Specialists and arbiters](#specialists-and-arbiters)
  - [Operational agents](#operational-agents)
  - [Skills](#skills)
  - [Patterns](#patterns)
  - [Contracts](#contracts)
  - [Project management: GitHub and Jira](#project-management-github-and-jira)
  - [Authenticating Jira and GitHub](#authenticating-jira-and-github)
- [Requirements](#requirements)

---

## What is Crucible

Crucible is a decomposed, orchestrator-driven subagent framework for Claude Code. It is a tree
of **agent definitions**, **skills**, and **JSON contracts** that deploy into a Claude Code
config directory (`~/.claude` by default) as symlinks. Once deployed, the primary Claude Code
agent reads the operating contract and changes how it behaves.

Three ideas run through the whole framework:

- **Orchestrator, not implementer.** For any coding task the primary agent delegates
  implementation to a matching `{tech}`-developer and review to a swarm of independent
  reviewers — it only implements directly when no subagent fits the stack.
- **The roster starts empty.** No hardcoded review list. Each subagent declares its own scope
  and applicability in its frontmatter; the orchestrator reads those declarations and earns
  every seat with a named risk, stating what each *exclusion* accepts.
- **The human owns every outward act.** Commits, pushes, tags, pull requests, issue/ticket
  writes, and the one destructive inbox purge are all consent-gated. The agent proposes and
  prepares; the human approves; only then does the write happen.

The authoritative contract is [`main-thread/CLAUDE.md`](./main-thread/CLAUDE.md) — deliberately
a thin loader. It carries the entry modes and the invariants; the actual procedures live in the
`flow-*` skills it binds. Start there to understand how a request becomes delegated, reviewed
work.

## At a glance

| | |
|---|---|
| **Entry modes** | 9 — orchestrate, review, direct, decision panel, external review, documentation, backlog, capture, unreviewed |
| **Developers** | 7 — Java, Kotlin, PHP, React, Rust, shell script, DevOps |
| **Reviewers** | 15 total — **7 `{tech}`-reviewers** (correctness floor): Java, Kotlin, PHP, React, Rust, shell script, DevOps · **8 `lens-*`** (language-agnostic quality): clean-code, security, performance, observability, test-quality, consistency, persistence, compatibility |
| **Specialists & arbiters** | 3 — `software-architect`, `decision-arbiter`, `review-arbiter` |
| **Operational agents** | 4 — `git-operator`, `project-manager`, `gtd-inbox-writer`, `docs-writer` |
| **Project management** | 2 active trackers — **GitHub** (issues + pull requests) and **Jira** (issues, components/versions, attachments, bulk, Agile) |
| **Patterns** | Orchestrated fix loop · blind decision panel · external-review adjudication |
| **Determinism** | Scripts are the sole writers for git, GitHub, Jira, and the GTD inbox |

Headline capabilities:

- **An orchestrated review swarm** — every non-trivial change is reviewed by the correctness
  reviewer for its stack plus each quality lens whose declared applicability the change meets,
  then a bounded fix loop drives gating findings to closure.
- **A decision panel** — for costly, hard-to-undo forked decisions, blind reviewers with
  different lenses plus a neutral arbiter that resolves disagreement by reasoning, not vote.
- **Dual-tracker project management** — author and file professional backlog artifacts on both
  GitHub and Jira, tuned to a declared audience, with every live write gated on consent.
- **A GTD capture inbox** — park a thought mid-session with a leading `dump:` / `park:` /
  `inbox:` directive; a deterministic script appends it verbatim, never executes it.

## How it works

A coding request flows through the orchestration procedure:

1. **Brief** — read the request *and* the code it touches; size the work, identify the stack.
2. **Derive the roster** — starting from empty, seat the `{tech}`-reviewer (correctness floor)
   and each applicable `lens-*`; state every exclusion and what it accepts.
3. **Gate** — present the plan and the *consequence* of getting it wrong; dispatch nothing
   without explicit approval.
4. **Build** — delegate to the `{tech}`-developer (or implement directly if no subagent fits).
5. **Review** — dispatch the swarm in parallel; each reviewer is read-only and returns a
   structured report.
6. **Loop** — round 1 fixes gating findings, round 2 verifies; a 3rd round only on an open
   CRITICAL/HIGH. MEDIUM/LOW become follow-ups.
7. **Summarize** — stack, roster, cycles, files, final verdict.

A change is not *done* until it has been reviewed — this binds to repository state (`git
status`), not to how the request was phrased.

## Deploying

### Human setup

`deploy.sh` discovers the framework by **marker, not by path**: every agent (any `*.md` with
`name:` + `description:` frontmatter), every skill (any directory containing `SKILL.md`), every
contract (`*.schema.json`), and the single `CLAUDE.md`. It symlinks each by name into a Claude
Code config directory (`~/.claude` by default).

```sh
./deploy/deploy.sh --dry-run   # preview: CREATE / REPLACE / DIVERGED / PRUNE
./deploy/deploy.sh             # apply
```

Before it applies anything (including under `--dry-run`), it fails fast on two checks: every
agent's `skills:` reference must resolve to a discovered skill, and — when deploying this
framework's own tree — a default roster of required agents (`decision-arbiter`, `review-arbiter`,
`software-architect`, `git-operator`, `docs-writer`) must all be discovered. Both are
configurable (`--required-agents`, `--no-verify-skill-refs`).

> ⚠️ **Deploying replaces the target's `CLAUDE.md` with no backup.** If you already have a
> personal `~/.claude/CLAUDE.md`, run `--dry-run` first and save a copy yourself before applying.
> (An automatic-backup mechanism is a tracked, not-yet-implemented item.)

Common flags: `--target`, `--source`, `--copy-agents`, `--no-prune`, `--only`,
`--required-agents`, `--no-verify-skill-refs`. Run `./deploy/deploy.sh --help` for the full
reference.

Exit codes: `0` success · `2` usage/argument error · `3` ambiguous source (a name collision, or
more than one `CLAUDE.md` under the root) · `4` an unresolved `skills:` reference · `5` a missing
required agent · `1` any other fatal error.

### Agentic setup

Because Crucible is plain files and one shell script, you can drive the whole setup
conversationally from inside Claude Code — useful if you'd rather not run the commands yourself.
A safe sequence:

1. Clone the repository and open it in Claude Code.
2. Ask the agent to run `./deploy/deploy.sh --dry-run` and **read back the CREATE / REPLACE /
   DIVERGED / PRUNE plan** — especially whether your existing `CLAUDE.md` shows as REPLACE.
3. If anything would be overwritten you want to keep, have the agent copy it aside first.
4. On your approval, ask the agent to run `./deploy/deploy.sh` to apply, then re-run
   `--dry-run` to confirm everything now reports as SKIP (already in place).

The dry-run-first, read-the-diff, then-apply loop is the same discipline the framework itself
enforces for outward acts — apply it here too.

## Reference

Each component below is listed with **what it is** and **when it is used**. The orchestrator
never consults a hardcoded list — it reads each agent's frontmatter `description:` to decide.

### Entry modes

Every request is routed into exactly one of nine modes, and the mode decides *who does the work*
and *what safeguards apply* — a build gets the full developer-plus-swarm treatment, a costly
decision gets a blind panel, an outward act gets a consent gate. You rarely name the mode: the
orchestrator infers it from the request, and — critically — the `UNREVIEWED` mode keys off
`git status` rather than any word, so changes can never quietly ship without a review. Modes are
defined in [`main-thread/CLAUDE.md`](./main-thread/CLAUDE.md):

| Mode | Trigger | What runs |
|---|---|---|
| **Orchestrate** | "orchestrate", or any build/implement/refactor/fix request | Developer → review swarm → gated fix loop |
| **Review** | "review" on existing code | Review swarm only, no developer |
| **Direct** | no subagent matches the stack | Orchestrator implements, then independent lenses still review |
| **Decision panel** | a complex, costly-to-undo forked decision | Blind reviewers + a neutral `decision-arbiter` |
| **External review** | an external/automated PR review to address | Advocates + the `review-arbiter` judge → fix → one response |
| **Documentation** | "document this", "write a README" | `docs-writer` drafts → fact-checked against the code → fix loop |
| **Backlog** | "file an issue/ticket", "carve an epic", "open a PR" | `project-manager` recommends + drafts → consent-gated tracker write |
| **Capture** | a leading `inbox:` / `dump:` / `park:` / `collect:` / `capture this:` directive | `gtd-inbox-writer` appends the thought verbatim (no gate) |
| **Unreviewed** | `git status` shows unreviewed changes you made | Review swarm on your own changes |

A cross-cutting **git/VCS flow** (commit, push, branch, tag) can fire off any mode: the
`git-operator` plans, the orchestrator exposes the message verbatim and executes only on consent.

### Developers

Implementation agents, one per stack. The orchestrator delegates the actual coding to the one
that matches the request. Each is a specialist that builds to the same shared `standard-*`
rubrics its reviewer later judges against — so developer and reviewer share one definition of
"good", and the handoff between them is a contract, not a guess.

| Agent | What it is | When it's used |
|---|---|---|
| `java-developer` | Enterprise JVM / Spring Boot implementer | Building or refactoring Java code |
| `kotlin-developer` | Kotlin / coroutines / Ktor implementer | Building or refactoring Kotlin code |
| `php-developer` | Laravel / Symfony implementer | Building or refactoring PHP code |
| `react-developer` | React + TypeScript (Next.js/Remix) implementer | Building or refactoring React UI |
| `rust-developer` | Systems & async Rust implementer | Building or refactoring Rust code |
| `shell-script-developer` | POSIX/Bash automation & CLI implementer | Writing shell scripts, entrypoints, CI steps |
| `devops-engineer` | Infrastructure-as-code implementer | Terraform, Helm, K8s, Dockerfiles, pipelines |

### Reviewers

This independent swarm is the heart of Crucible — **the code's author is never its only judge.**
All reviewers are read-only; they report, they never touch the code. The `{tech}`-reviewer is the
**correctness floor** for its stack (logic no generic lens covers), and the `lens-*` reviewers are
language-agnostic quality lenses, each seated only when its declared applicability matches the
change — so a small change gets a small swarm and a risky one gets the scrutiny it earns.

**Correctness floor — one per stack:**

| Reviewer | What it is | When it's used |
|---|---|---|
| `{tech}`-reviewer | Correctness + language-specific hazards for that stack (`java-reviewer`, `kotlin-reviewer`, `php-reviewer`, `react-reviewer`, `rust-reviewer`, `shell-script-reviewer`, `devops-reviewer`) | Every orchestrated change in that stack |

**Quality lenses — seated by applicability:**

| Reviewer | What it is | When it's used |
|---|---|---|
| `lens-clean-code-reviewer` | Structure, DRY/SRP/SOLID, self-documenting code | Non-trivial production code changes |
| `lens-security-reviewer` | App security (OWASP/ASVS/CWE) | Any change touching a trust boundary — security floor |
| `lens-performance-reviewer` | Algorithmic & access-pattern cost | Hot paths, loops, large/unbounded data |
| `lens-observability-reviewer` | Logging, metrics, tracing, PII leakage | Changes with runtime behavior worth observing |
| `lens-test-quality-reviewer` | Whether tests verify behavior, not noise | Changes that touch or warrant tests |
| `lens-consistency-reviewer` | Conformance to the project's own conventions | Structural / placement / naming changes |
| `lens-persistence-reviewer` | Data-layer correctness (integrity, atomicity, migrations) | Reads/writes to a durable store or schema changes |
| `lens-compatibility-reviewer` | Backward compatibility of a contract | Public API, wire format, schema, or CLI changes |

### Specialists and arbiters

| Agent | What it is | When it's used |
|---|---|---|
| `software-architect` | Design/architecture decision-maker | Costly forked design calls; a seat in the decision panel |
| `decision-arbiter` | Neutral synthesizer of disagreeing reviews | The final seat of a decision panel |
| `review-arbiter` | Per-finding judge (real defect? disposition?) | The judge seat of the external-review pattern |

### Operational agents

Not tied to a tech stack. These embody the framework's determinism rule: the **agent plans and
drafts, a script performs the write, and the human authorizes anything that leaves the machine.**
No agent hand-writes a commit, a ticket, or a log line — it decides *what* should happen and a
deterministic script makes it happen, so the outward record is reproducible and never improvised.

| Agent | What it is | When it's used |
|---|---|---|
| `git-operator` | Plans branches, atomic signed commits, pushes, tags | Landing already-made changes as VCS operations |
| `project-manager` | Authors backlog artifacts + operates GitHub/Jira | Filing issues/tickets/epics/bugs, opening PRs |
| `gtd-inbox-writer` | Appends one captured thought to the GTD inbox | A leading capture directive (`dump:`, `park:`, …) |
| `docs-writer` | Writes minimal, single-purpose documentation | An explicit documentation request |

### Skills

Skills are bound on demand, not memorized. Three kinds:

| Kind | What it is | When it's used |
|---|---|---|
| `flow-*` | The orchestrator's playbooks — `flow-orchestration`, `flow-decision`, `flow-external-review`, `flow-documentation`, `flow-project-management`, `flow-git-operations`, `flow-inbox` | Bound by the main thread when a matching mode fires |
| `standard-*` | Shared quality rubrics — developers build to them, reviewers judge against them (per-language `tech/`, per-lens, plus judging/documentation/backlog rubrics) | Referenced during build and review |
| `procedure-*` | Script-backed deterministic procedures — `procedure-gh-issues`, `procedure-gh-pr`, `procedure-jira`, `procedure-git-ops`, `procedure-inbox-capture`, and their auth/identity helpers | Bound by an operational agent to run its scripts |

### Patterns

Crucible's multi-agent workflows. The **orchestrated fix loop** is the spine — the central
pattern that runs on every build; the other two are on-demand judgment harnesses (under
[`patterns/`](./patterns)) that resolve calls a single reviewer would get wrong.

| Pattern | What it is | When it's used |
|---|---|---|
| **Orchestrated fix loop** | The framework's spine: an independent swarm reviews the developer's work, and a bounded, seat-persistent loop drives every gating finding to closure before the change is called done — a reviewer that raised a blocker keeps its seat until *it* agrees the blocker is gone. | Every orchestrated build or review |
| **Decision panel** | Neutralizes the orchestrator's own bias: reviewers with deliberately different lenses judge *blind*, then a neutral `decision-arbiter` resolves their disagreement by reasoning and evidence — never a vote. | A costly, hard-to-undo forked decision of any kind |
| **External review** | Adjudicates each incoming review finding on its merits: PRO/CON advocates argue it, a `review-arbiter` judge rules real-or-not per finding — so you fix what's genuinely broken, refute what isn't, and respond once. | Addressing an external/automated PR review |

The two arbiter-led patterns share `standard-judging`, the judge's constitution.

### Contracts

The externalized JSON schemas in [`contracts/`](./contracts) — the wire shapes agents produce,
so structured output is validated at the tool layer rather than parsed from prose:

| Contract | Shape it defines |
|---|---|
| `review-finding-report.schema.json` | A reviewer's structured findings report |
| `finding-verdict.schema.json` · `report-verdict.schema.json` · `severity.schema.json` | Finding/report verdicts and the severity vocabulary |
| `decision-lawyer-finding.schema.json` | A decision-panel lawyer's structured finding |
| `review-arbiter-verdict.schema.json` · `external-review-*.schema.json` | External-review advocate/verifier/ledger verdicts |
| `audience-register.schema.json` | The audience + register a backlog artifact is tuned to |
| `inbox-entry.schema.json` | One line of the GTD inbox log |

### Project management: GitHub and Jira

The `project-manager` recommends the right artifact type, drafts it tuned to a declared
**audience** (`agent` / `human` / `both`, with a register for humans), and — on explicit consent —
the write is executed. Scripts are the sole writers; nothing reaches a live tracker without
approval. Both trackers are active:

| Tracker | Capabilities | Backing |
|---|---|---|
| **GitHub** | Issues (create, comment, update, close, labels, projects) and **pull requests** (open, update) | `procedure-gh-issues`, `procedure-gh-pr` |
| **Jira** | Issues (create, comment, transition, update); components, versions & releases; attachments incl. inline images; bulk operations; and the **Agile** surface — boards, sprints, backlog, epics, plus sprint lifecycle (create/start/close) | `procedure-jira` engine over the Jira REST v3 + Agile v1.0 APIs |

The Jira surface is **full-blown, script-driven project management** — not a thin wrapper. A single
deterministic engine (`procedure-jira`) is the sole writer for every operation, so each write is
reproducible and auditable rather than improvised. Ticket and comment bodies are authored in
**markdown and converted to Atlassian Document Format (ADF)** — headings, lists, tables, code
blocks, and panels all render natively — and real **attachments** (files, plus images embedded
inline in the body) ship alongside. That combination is what makes agent-run Jira **token
efficient**: instead of transcribing a stack trace, a spec, or a screenshot into thousands of
tokens of prose, the agent attaches the artifact and writes a tight, richly-formatted ticket in
one call — professional-grade Jira management at a fraction of the token cost of pasting
everything inline.

### Authenticating Jira and GitHub

The project-management flows require a one-time authentication per tracker. Credentials are stored
locally and securely — the scripts never put a token on the command line or in logs, and before any
live write the framework re-confirms the active site/account with you, so a ticket never lands on
the wrong tracker or under the wrong login.

**Jira** — run the interactive login (it prompts for your site, email, and API token; the token is
entered with terminal echo off):

```sh
$HOME/.claude/skills/procedure-jira-auth/scripts/jira-login.sh
```

- Create an API token from your Atlassian account: **id.atlassian.com → Security → API tokens**.
- The credential is stored as a `600` file under `~/.claude/crucible/jira/credentials/`. You can
  hold **several sites at once** (e.g. one per client); the first stored becomes the default.
- Check status and manage sites:
  ```sh
  $HOME/.claude/skills/procedure-jira-auth/scripts/jira-auth-status.sh
  $HOME/.claude/skills/procedure-jira-auth/scripts/jira-accounts.sh list
  $HOME/.claude/skills/procedure-jira-auth/scripts/jira-accounts.sh set-default --site <site>
  ```

**GitHub** — the framework uses the GitHub CLI (`gh`). Authenticate the standard way:

```sh
gh auth login
```

- Check which account the framework will act as:
  ```sh
  $HOME/.claude/skills/procedure-git-auth/scripts/gh-auth-status.sh
  ```
- To switch between multiple logged-in accounts, use `gh auth switch`, or the framework's helper
  `$HOME/.claude/skills/procedure-git-auth/scripts/manage_gh_accounts.sh`.

## Requirements

- **Claude Code** — the host for the framework.
- **A POSIX shell** (`sh`) — the deploy script and all `procedure-*` scripts are POSIX `sh`.
- **`jq`** — JSON tooling for the Jira/GitHub/inbox procedures.
- **`git`** — for the VCS operations.
- **`gh`** (GitHub CLI) — for GitHub issues and pull requests.
- A Jira instance and API token — only if you use the Jira project-management surface.
