# Crucible

**Crucible turns Claude Code from a single implementer into an orchestrated team.**

Out of the box, one agent writes the code, reviews its own work, and decides on its own when to
commit. It is its own reviewer and its own gatekeeper. Crucible breaks that up: the primary agent
becomes an **orchestrator** that reads a contract ([`CLAUDE.md`](./CLAUDE.md)), assembles a roster
of specialized subagents, and drives a **gated build → review → fix loop**. Work is implemented by
one agent, judged by others, and every outward or destructive act — a commit, a push, a ticket, a
live tracker write — waits on explicit human consent. Where determinism matters, **scripts own
every byte written** and the agents only decide which script to run.

The result is separation of concerns applied to an AI coding workflow: the thing that does the work
is never the only thing that checks it, and nothing irreversible happens without a human in the
loop.

---

## Contents

- [What Crucible is](#what-crucible-is)
- [Install it — the Crucible Management Hub](#install-it--the-crucible-management-hub)
- [How a request flows](#how-a-request-flows)
- [Entry modes — how you talk to it](#entry-modes--how-you-talk-to-it)
- [What's in each domain](#whats-in-each-domain)
- [Authenticating GitHub and Jira](#authenticating-github-and-jira)
- [Requirements](#requirements)

---

## What Crucible is

Crucible is a tree of **agent definitions**, **skills**, and **JSON contracts** organized into four
domains. You install the domains you want into a Claude Code config directory (`~/.claude` by
default) as symlinks. Once installed, the primary Claude Code agent reads the operating contract
and changes how it behaves.

Three ideas run through the whole framework:

- **Orchestrator, not implementer.** For any coding task the primary agent delegates implementation
  to a matching `{tech}`-developer and correctness review to that stack's `{tech}`-reviewer. It
  implements directly only when no subagent fits the stack.
- **The roster starts empty.** No hardcoded review list. Each subagent declares its own scope in
  its frontmatter; the orchestrator reads those declarations and earns every seat with a named
  risk, stating what each *exclusion* accepts.
- **The human owns every outward act.** Commits, pushes, tags, pull requests, issue writes, and the
  one destructive inbox purge are all consent-gated. The agent proposes and prepares; the human
  approves; only then does the write happen.

The authoritative contract is [`CLAUDE.md`](./CLAUDE.md), deliberately a thin loader: it carries
the entry modes and the invariants, while the actual procedures live in the `flow-*` skills it
binds. Read it to understand how a request becomes delegated, reviewed work.

---

## Install it — the Crucible Management Hub

The **hub** ([`deploy/hub/`](./deploy/hub)) is the one way in. It discovers every component in this
tree at runtime, shows you what is installed, installs and removes what you choose, and checks that
your environment can actually run it. There is no separate deploy script.

Every screen exists twice, on purpose: an **interactive menu** for a human, and an **exact
flag-driven equivalent** for a script or an agent. A fact one of them can read and the other
cannot would be a gap.

### First run

```sh
./deploy/hub/crucible-hub
```

The Main menu opens (a TTY is required — off a terminal, use the commands below):

```
  1. Status           — which domains are installed
  2. List             — installed vs available components
  3. Doctor           — required tools + account health
  4. Accounts         — GitHub / Jira
  5. Install all      — every domain, technology and backend
  6. Install          — choose domains
  7. Uninstall all
  8. Uninstall        — choose technologies or backends
  9. Exit
```

From any screen: `?` shows help, `b` goes back one level, `q` quits.

1. **Pick `6` (Install).** A checklist asks which domains you want: Software Development, Project
   Management, Getting Things Done. Type a row number or name and press Enter to select or
   deselect it; combine several with `1,3,5` or a range `1-5`; `a` selects all, `n` none. Enter on
   an empty prompt confirms.
2. **Choose each domain's sub-selection.** Software Development asks which technologies (each one
   installs its developer agent, its reviewer and its standard together). Project Management asks
   for GitHub, Jira, or both. GTD has no sub-selection. A domain that needs one and gets none is
   never given a guessed default — the screen says so and re-prompts.
3. **Read the preview.** Nothing has been written yet. The preview lists exactly what will be
   created, replaced and skipped, including the first-run bundle ([`CLAUDE.md`](./CLAUDE.md) plus
   the contract schemas) and whether an existing `CLAUDE.md` will be backed up.
4. **Confirm at the `[Y/n]` prompt.** Enter accepts. `b` returns to the checklist with your
   selection intact; `q` asks before discarding it.
5. **Run `3` (Doctor).** It reports required tools, account health, and any component that has
   diverged from source — and separates *problems* (something installed cannot work) from *notes*
   (something that only matters for a domain you have not installed).
6. **Run `4` (Accounts)** to authenticate GitHub and Jira. See
   [Authenticating GitHub and Jira](#authenticating-github-and-jira).

`5` (Install all) takes every domain, technology and backend in one step, through the same preview
and confirmation.

> **Where things land.** Agents symlink to `~/.claude/agents/<name>.md`, skills to
> `~/.claude/skills/<name>/`, the contract schemas to `~/.claude/crucible/contracts/`, and the
> operating contract to `~/.claude/CLAUDE.md`. They are symlinks into this clone, so `git pull`
> updates a live installation in place — and moving or deleting the clone leaves the target
> dangling (the hub reports those as **orphaned**). Point elsewhere with `--target DIR`.

> **An existing `CLAUDE.md` is backed up, not lost.** A foreign `CLAUDE.md` at the target — a real
> file, or a symlink outside the framework — is copied to a timestamped
> `CLAUDE.md.backup.<UTC>` beside it before the framework's contract is installed. The preview says
> so *before* you confirm, not afterwards.

### Every screen, as a command

Run any of these directly, or as `crucible-hub SUBCOMMAND`. Add `--help` to any one for its full
option reference.

| Menu screen | Command |
|---|---|
| Status | `crucible-hub status` |
| List | `crucible-hub list` |
| Doctor | `crucible-hub doctor` |
| Accounts | `crucible-hub accounts status\|switch-github\|reauth-github\|configure-jira\|reauth-jira` |
| Install | `crucible-hub install --domains=CSV [--technologies=CSV] [--pm-backends=CSV] --apply` |
| Install all | `crucible-hub install --all --apply` |
| Uninstall | `crucible-hub uninstall --components=CSV --apply` |
| Uninstall all | `crucible-hub uninstall --all --apply --confirm=UNINSTALL` |

Shared options: `--target DIR` (deployed config dir, default `$HOME/.claude`), `--source DIR`
(framework root to scan, default this tree), `--format=text|env|json`, `--no-color`. Install and
uninstall add `--non-interactive`, `--accessible` (ASCII fallback for every non-ASCII symbol) and
`--details` (itemize a bulk result instead of summarizing it).

**`--format=env` and `--format=json` are what make the hub agent-drivable.** Both emit the same
facts the text screen shows — per-domain state, per-component rows, counts, a `HUB_STATUS` of `ok`
or `blocked`, and a closed set of `HUB_BLOCKED_REASON` values. `json` needs `jq`; nothing else
does.

### Nothing is written without saying so first

- **`--apply` is required to write, on every path, terminal or not.** Without it you get the
  preview and nothing else. A flag-driven selection never reaches the confirm prompt at all, so a
  stray Enter cannot turn a dry run into an install. Only the pure interactive walk
  confirms-then-writes, because walking the checklists *is* the request.
- **A missing sub-selection blocks rather than guesses.** `install --domains=software-development`
  with no `--technologies` exits blocked (`selection_required`), never with some default stack.
- **`uninstall --all` is the one critical-tier flow.** On a terminal you type the word `UNINSTALL`
  in full; without one you must pass `--confirm=UNINSTALL`, or the command fails loud rather than
  assuming consent. It removes everything installed plus `CLAUDE.md` and the contract schemas, and
  can restore a chosen `CLAUDE.md` backup on the way out (`--restore-backup=TIMESTAMP|none`).
- **Selective uninstall works at the granularity a human installs at** — one row per technology,
  one per Project Management backend. A domain's baseline comes out by cascade once its last
  technology or backend is gone, announced explicitly in the preview. GTD has no sub-selection, so
  only `--all` reaches it.

Exit codes: `0` preview shown, nothing to do, cancelled, or applied · `1` blocked or a write
failure · `2` usage error · `3` the user quit an interactive screen.

The design rationale behind each screen lives in the script headers under
[`deploy/hub/`](./deploy/hub) and in the UI spec at
[`.crucible/docs/specs/2026/07/30/`](./.crucible/docs/specs/2026/07/30).

---

## How a request flows

A coding request runs through four separate, independently-gated procedures — not one, because
their costs differ wildly and shouldn't all be paid on every build:

1. **Spec** ([`flow-spec`](./software-development/flows/flow-spec)) — for cross-repo or
   multi-tech-pair work, and on request for a single repo. `software-architect` drafts a contract,
   the human approves it, and every parallel tech pair builds against that same document.
2. **Implement** ([`flow-implementation`](./software-development/flows/flow-implementation)) —
   brief → gate → the `{tech}-developer` builds → the `{tech}-reviewer` reviews for correctness → a
   bounded fix loop (round 1 fixes gating findings, round 2 verifies, a 3rd only on an open
   CRITICAL/HIGH). **Never a lens.** This is the safety net every real build gets.
3. **Review** ([`flow-review`](./software-development/flows/flow-review)) — *on demand only.*
   Derives a lens roster from the confirmed scope, gates it, dispatches the swarm in parallel, and
   persists a durable, trackable report. Runs no fix loop of its own; findings re-enter step 2.
4. **Test** ([`flow-testing`](./software-development/flows/flow-testing)) — *last, on demand only.*
   Fires once the human confirms the implementation is right. `tests-developer` writes the tests —
   never the developer that wrote the code under test — and `lens-test-quality-reviewer` verifies
   them.

**Nothing here fires from repository state.** An earlier design keyed the full review swarm off
`git status`, which is exactly how a misjudged cross-repo build could burn hours and millions of
tokens polishing the wrong implementation before a human got a cheap look at it. The one surviving
state-based check is the **commit gate**: before any commit, it asks whether the diff has been
through at least step 2, and won't assume either answer if unsure. A question, not a swarm.

---

## Entry modes — how you talk to it

Every request routes into exactly one of eleven modes, and the mode decides *who does the work* and
*what safeguards apply*. You rarely name the mode — the orchestrator infers it. The modes are
defined in [`CLAUDE.md`](./CLAUDE.md).

| Mode | Trigger | What runs |
|---|---|---|
| **Implement** | a build/implement/refactor/fix request, or "review this" naming no lens | Developer → `{tech}`-reviewer → gated fix loop — tech pair only, never a lens |
| **Spec** | cross-repo work, parallel tech pairs, a forked interface decision, or an explicit spec-first ask | `software-architect` drafts a contract → gate → durable artifact every pair builds against |
| **Review** | an explicit ask for a full/lens review — never automatic | Scope confirmed → lens swarm derived from it → gate → durable, trackable report |
| **Test** | the human's explicit confirmation an implementation is right | `tests-developer` writes tests → mandatory test-quality pass → bounded fix loop |
| **Direct** | no subagent matches the stack | Orchestrator implements, self-checks via an execution test |
| **Tech-pair** | "I need a new tech pair" (bare, or "...for Go") | Poll → collision check → gate → research swarm → generate the pair in order → lens review before deploy → human deploys |
| **Decision panel** | a complex, costly-to-undo forked decision | Blind reviewers with different lenses + a neutral `decision-arbiter` |
| **External review** | an external/automated PR review to address | Advocates + the `review-arbiter` judge → fix → one response |
| **Documentation** | "document this", "write a README" | `docs-writer` drafts → fact-checked against the code → fix loop |
| **Backlog** | "file an issue/ticket", "carve an epic" | `project-manager` recommends + drafts → consent-gated tracker write |
| **Capture** | a leading `inbox:` / `dump:` / `park:` / `collect:` / `capture this:` | `gtd-inbox-writer` appends the thought verbatim, never executes it |

A cross-cutting **git/VCS flow** ([`flow-git-operations`](./software-development/flows/flow-git-operations))
can fire from any mode: the `git-operator` plans branches, atomic signed commits, pushes, tags and
pull requests; the orchestrator exposes the message verbatim and executes only on consent.

---

## What's in each domain

Install any subset. Run `crucible-hub list` for the live, exhaustive inventory — each agent and
skill documents itself in its own file, so the list below is a map, not a catalogue.

| Domain | What you get | Sub-selection |
|---|---|---|
| [`software-development/`](./software-development) | A developer + reviewer pair per technology, 8 language-agnostic review lenses, the orchestration flows, the git operator, the arbiters and the architect | One or more **technologies** |
| [`project-management/`](./project-management) | The `project-manager` agent: authors backlog artifacts tuned to a declared audience and operates the tracker | **GitHub**, **Jira**, or both |
| [`gtd/`](./gtd) | `gtd-inbox-writer` for zero-judgment capture, plus `flow-inbox` for triage and processing | none |
| [`accounts/`](./accounts) | The shared GitHub auth procedure. Installed automatically when a domain needs it, removed when none does | — |

Each domain follows the same shape: `agents/` (agent definitions, each with its own `skills/`),
`flows/` (the orchestrator's playbooks), `contracts/` (JSON schemas for structured output), and —
in Software Development — `shared/` (the `standard-*` rubrics developers build to and reviewers
judge against) and `templates/` (never deployed).

**Software Development** carries the correctness floor and the quality lenses, and the difference
matters. A `{tech}`-reviewer owns correctness for its stack and runs on **every** build. The eight
`lens-*` reviewers — clean-code, security, performance, observability, test-quality, consistency,
persistence, compatibility — are language-agnostic and run **only** when a human asks for a review
pass. Test authoring is separate again: `tests-developer` is tech-agnostic, and
[`build-core`](./software-development/shared/build-core) structurally forbids a `{tech}`-developer
from touching a test file at all.

**Project Management** is script-driven, not a thin wrapper. GitHub covers issues (create, comment,
update, close, labels, projects); Jira covers issues, components, versions and releases,
attachments, bulk operations and the full Agile surface — boards, sprints, backlog, epics, sprint
lifecycle — over the REST v3 and Agile v1.0 APIs. Ticket bodies are authored in markdown and
converted to Atlassian Document Format, and real files attach alongside. That is what makes
agent-run Jira token-efficient: attach the stack trace or the screenshot, write a tight ticket,
skip transcribing thousands of tokens of prose. Pull requests are **not** here — they are VCS work
and belong to the `git-operator`.

**GTD** parks a thought mid-session. A leading `dump:` / `park:` / `inbox:` directive stores the
remainder verbatim through a deterministic script; the text is data, never a command.

---

## Authenticating GitHub and Jira

Credentials are stored locally. The scripts never put a token on a command line or in a log, and
before any live write the framework re-confirms the active site or account with you.

The hub's Accounts screen is the front door — it reports both states and delegates to each
procedure's own script:

```sh
crucible-hub accounts status          # who the framework will act as
crucible-hub accounts switch-github   # switch between, or log in to, GitHub accounts
crucible-hub accounts configure-jira  # add a Jira site
```

**GitHub** uses the GitHub CLI. `gh auth login` works exactly as it always does; `gh auth switch`
and the hub's Accounts screen both change the active account.

**Jira** prompts for your site, email, and an API token (created at **id.atlassian.com → Security →
API tokens**, entered with terminal echo off). Each credential is stored as a `600` file under
`~/.claude/crucible/jira/credentials/`; you can hold **several sites at once** and the first stored
becomes the default. To manage them directly:

```sh
$HOME/.claude/skills/procedure-jira-auth/scripts/jira-auth-status.sh
$HOME/.claude/skills/procedure-jira-auth/scripts/jira-accounts.sh list
$HOME/.claude/skills/procedure-jira-auth/scripts/jira-accounts.sh set-default --site <site>
```

---

## Requirements

`crucible-hub doctor` checks all of these and tells you which are missing.

- **Claude Code** — the host for the framework.
- **A POSIX shell** (`sh`) — the hub and every `procedure-*` script are POSIX `sh`.
- **`git`** — for the VCS operations.
- **`gh`** (GitHub CLI) — for GitHub issues and pull requests.
- **`jq`** — the Jira/GitHub/inbox procedures, and the hub's `--format=json`.
- **`curl`** — drives the Jira REST calls.
- **`gpg` or `ssh-keygen`** (one of the two) — backs the signed commits `git-operator` produces.
- A Jira instance and API token — only if you install the Jira backend.
