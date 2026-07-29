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
| **Entry modes** | 10 — implement, spec, review, test, direct, decision panel, external review, documentation, backlog, capture |
| **Developers** | 7 `{tech}` pairs — Java, Kotlin, PHP, React, Rust, shell script, DevOps — plus 1 tech-agnostic `tests-developer` |
| **Reviewers** | 15 total — **7 `{tech}`-reviewers** (correctness floor): Java, Kotlin, PHP, React, Rust, shell script, DevOps · **8 `lens-*`** (language-agnostic quality, on-demand only): clean-code, security, performance, observability, test-quality, consistency, persistence, compatibility |
| **Specialists & arbiters** | 3 — `software-architect`, `decision-arbiter`, `review-arbiter` |
| **Operational agents** | 4 — `git-operator`, `project-manager`, `gtd-inbox-writer`, `docs-writer` |
| **Project management** | 2 active trackers — **GitHub** (issues + pull requests) and **Jira** (issues, components/versions, attachments, bulk, Agile) |
| **Patterns** | Bounded tech-pair fix loop · on-demand lens review · cross-repo spec gate · blind decision panel · external-review adjudication |
| **Determinism** | Scripts are the sole writers for git, GitHub, Jira, and the GTD inbox |

Headline capabilities:

- **A tech-pair safety net, always on** — every real build gets a correctness review from its
  stack's `{tech}`-reviewer, bounded to 3 rounds, before it's called done. Never a lens, never
  automatic beyond that: the deeper quality swarm is a separate, deliberate ask.
- **An on-demand lens review** — explicitly requested, never triggered by a build finishing or by
  how large a change looks. Derives its roster from the actual diff, then persists a durable,
  trackable report — not just conversation output.
- **A cross-repo spec gate** — before dispatching parallel tech pairs across repos, a
  `software-architect`-drafted, human-approved contract they all build against, so independent
  interpretation can't let three repos quietly drift from each other.
- **Tests, always last** — authored only once the human confirms an implementation is right, by a
  dedicated `tests-developer` agent that never wrote the code under test.
- **A decision panel** — for costly, hard-to-undo forked decisions, blind reviewers with
  different lenses plus a neutral arbiter that resolves disagreement by reasoning, not vote.
- **Dual-tracker project management** — author and file professional backlog artifacts on both
  GitHub and Jira, tuned to a declared audience, with every live write gated on consent.
- **A GTD capture inbox** — park a thought mid-session with a leading `dump:` / `park:` /
  `inbox:` directive; a deterministic script appends it verbatim, never executes it.

## How it works

A coding request flows through four separate, independently-gated procedures — not one, because
their costs are wildly different and shouldn't all be paid on every build:

1. **Spec** *(cross-repo or multi-tech-pair work only)* — `software-architect` drafts a contract,
   a `flow-decision` panel resolves it first if the interface is genuinely contested (propose-only,
   never auto-fired), the human approves it, and every parallel tech pair builds against that same
   document.
2. **Implement** — brief → gate → the `{tech}-developer` builds → the `{tech}-reviewer` reviews for
   correctness → a bounded fix loop (round 1 fixes gating findings, round 2 verifies, a 3rd round
   only on an open CRITICAL/HIGH). **Never a lens.** This is the safety net every real build gets.
3. **Review** *(on demand only)* — explicitly requested, never automatic. Derives the lens roster
   from the actual diff, gates it, dispatches the swarm in parallel, and persists a durable,
   trackable report (one per repo in cross-repo work). Runs no fix loop of its own — findings are
   addressed by re-entering step 2.
4. **Test** *(last, on demand only)* — fires only once the human confirms the implementation is
   right. A dedicated `tests-developer` agent writes the tests — never the developer that wrote the
   code under test.

**The only thing that still checks repository state is the commit gate**: before any commit, it
asks whether the diff has been through at least step 2's tech-pair loop, and won't assume either
answer if unsure. That's the whole surviving safety net for "nothing ships unreviewed" — a
question, not a swarm.

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

Before it applies anything (including under `--dry-run`), it fails fast on three checks: every
agent's `skills:` reference must resolve to a discovered skill; when deploying this framework's
own tree, a default roster of required agents (`decision-arbiter`, `review-arbiter`,
`software-architect`, `git-operator`, `docs-writer`) must all be discovered; and, also only for
this framework's own tree by default, a default set of required runtime tools (`git`, `gh`, `jq`,
`curl`, and one of `gpg`/`ssh-keygen`) must be present on `PATH`. All three are configurable
(`--required-agents`, `--required-tools`, `--no-verify-skill-refs`).

> ℹ️ **An existing `CLAUDE.md` is backed up, not lost.** If the target already has a foreign
> `CLAUDE.md` (a real file, or a symlink outside the framework), deploy first preserves it to a
> timestamped `<target>/CLAUDE.md.backup.<UTC>` and then installs the framework's contract.
> Re-deploys are idempotent — an already-deployed framework contract is left untouched (no
> duplicate backups). Run `--dry-run` first to preview the `BACKUP` / `REPLACE` plan.

Common flags: `--target`, `--source`, `--copy-agents`, `--no-prune`, `--only`,
`--required-agents`, `--required-tools`, `--no-verify-skill-refs`. Run `./deploy/deploy.sh --help`
for the full reference.

Exit codes: `0` success · `2` usage/argument error · `3` ambiguous source (a name collision, or
more than one `CLAUDE.md` under the root) · `4` an unresolved `skills:` reference · `5` a missing
required agent · `6` a missing required runtime tool (nothing applied) · `1` any other fatal
error.

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

Every request is routed into exactly one of ten modes, and the mode decides *who does the work*
and *what safeguards apply* — a build gets the tech pair, a deep review is a separate deliberate
ask, a costly decision gets a blind panel, an outward act gets a consent gate. You rarely name the
mode: the orchestrator infers it from the request. **None of these fire from repository state
except the commit gate** — a deliberate change from an earlier design that keyed the full review
swarm off `git status`, discovered to be exactly how a misjudged cross-repo build could burn hours
and millions of tokens polishing the wrong implementation before a human ever got a cheap look at
it. Modes are defined in [`main-thread/CLAUDE.md`](./main-thread/CLAUDE.md):

| Mode | Trigger | What runs |
|---|---|---|
| **Implement** | a build/implement/refactor/fix request, or "review this" naming no lens | Developer → `{tech}`-reviewer → gated fix loop — tech pair only, never a lens |
| **Spec** | cross-repo work, multiple tech pairs in parallel, or a forked interface decision | `software-architect` drafts a contract → gate → durable artifact every parallel pair builds against |
| **Review** | an explicit ask for a full/lens review — never automatic | On-demand lens swarm, derived from the diff → gate → durable, trackable report |
| **Test** | the human's explicit confirmation an implementation is right | `tests-developer` (never the developer) writes tests against the approved code |
| **Direct** | no subagent matches the stack | Orchestrator implements, self-checks via an execution test |
| **Decision panel** | a complex, costly-to-undo forked decision | Blind reviewers + a neutral `decision-arbiter` |
| **External review** | an external/automated PR review to address | Advocates + the `review-arbiter` judge → fix → one response |
| **Documentation** | "document this", "write a README" | `docs-writer` drafts → fact-checked against the code → fix loop |
| **Backlog** | "file an issue/ticket", "carve an epic", "open a PR" | `project-manager` recommends + drafts → consent-gated tracker write |
| **Capture** | a leading `inbox:` / `dump:` / `park:` / `collect:` / `capture this:` directive | `gtd-inbox-writer` appends the thought verbatim (no gate) |

A cross-cutting **git/VCS flow** (commit, push, branch, tag) can fire off any mode: the
`git-operator` plans, the orchestrator exposes the message verbatim and executes only on consent —
and before any commit, checks whether the diff has been through at least the tech pair.

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

**Test authoring is deliberately separate from the above.** `tests-developer` is tech-agnostic — one
agent, not a per-stack pair — because what makes a test good is a universal question; only test
framework syntax is language-specific, and that's a briefing detail, not a reason for N more
agents. It lives here under Developers, not among the operational agents, because it writes real
executable code that ships and must run — but it is never the same agent that wrote the code under
test, and `build-core` structurally forbids the `{tech}`-developer from touching a test file at
all. It's dispatched only once the human explicitly confirms an implementation is right.

### Reviewers

This independent swarm is the heart of Crucible — **the code's author is never its only judge.**
All reviewers are read-only; they report, they never touch the code. The `{tech}`-reviewer is the
**correctness floor** for its stack (logic no generic lens covers) and runs as part of every build,
bounded to 3 rounds. The `lens-*` reviewers are language-agnostic quality lenses — seated by
declared applicability when they run, but **they never run automatically**: a lens pass is always
an explicit, separate ask, on the diff already produced by the tech pair.

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
| `flow-*` | The orchestrator's playbooks — `flow-implementation`, `flow-spec`, `flow-review`, `flow-testing`, `flow-decision`, `flow-external-review`, `flow-documentation`, `flow-project-management`, `flow-git-operations`, `flow-inbox` | Bound by the main thread when a matching mode fires |
| `standard-*` | Shared quality rubrics — developers build to them, reviewers judge against them (per-language `tech/`, per-lens, plus judging/documentation/backlog rubrics) | Referenced during build and review |
| `procedure-*` | Script-backed deterministic procedures — `procedure-gh-issues`, `procedure-gh-pr`, `procedure-jira`, `procedure-git-ops`, `procedure-inbox-capture`, and their auth/identity helpers | Bound by an operational agent to run its scripts |

### Patterns

Crucible's multi-agent workflows. The **tech-pair fix loop** is the spine — the one pattern that
runs on every build; the rest are on-demand — either a judgment harness (under
[`patterns/`](./patterns)) that resolves calls a single reviewer would get wrong, or a deliberately
separate, explicitly-requested procedure.

| Pattern | What it is | When it's used |
|---|---|---|
| **Tech-pair fix loop** | The framework's spine: the `{tech}-reviewer` checks the developer's work for correctness, and a bounded, seat-persistent loop drives every gating finding to closure before the change is called done. Never includes a lens. | Every build (`flow-implementation`) |
| **On-demand lens review** | A separate, explicitly-requested pass: quality lenses derived from the actual diff, gated, dispatched in parallel, persisted to a durable report. Never triggered by a build finishing. | Whenever a human asks for deeper scrutiny (`flow-review`) |
| **Cross-repo spec gate** | A `software-architect`-drafted, human-approved contract every parallel tech pair builds against, so independent repos can't quietly drift from each other or from intent. | Cross-repo or multi-tech-pair work (`flow-spec`) |
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
