---
name: procedure-gitlab-auth
description: The procedure the git-operator (before any GitLab MR write) and the project-manager (before any GitLab issue write) each run to confirm the correct GitLab CLI ACCOUNT. It wraps two highly-portable, deterministic scripts — scripts/glab-auth-status.sh (agent-friendly, non-interactive: reports whether glab is authenticated and exactly which account + host) and scripts/manage_glab_accounts.sh (USER-interactive: the human logs in / re-authenticates an instance). Before any glab action the caller resolves the active account, presents it, and asks the user to confirm it is the right login; if not, the USER logs in via the interactive script and the caller re-verifies. Note the one structural difference from the GitHub sibling: glab has NO `auth switch` subcommand and keeps ONE credential per instance, so "switch account" is not an action here — authenticating the instance IS the switch, and picking between several configured accounts is done by scoping the status script with --hostname. It does NOT define commit/branch/MR/tag conventions (the standard-git-* skills) or the signing identity (procedure-git-identity — the separate signing gate). Consumed by two callers — the git-operator and the project-manager — the same reason procedure-github-auth lives here rather than nested under one agent's own skills/: a skill with genuinely more than one domain consumer belongs in the cross-domain, top-level accounts/ location (contrast procedure-jira-auth, whose one-consumer test fails, so it stays nested under project-management/).
---

# Procedure: Git/GitLab Account Auth Gate

The **one** gate every GitLab operation (open/update a merge request, cut a release) passes first. Because a user commonly works across GitLab instances (gitlab.com plus one or more self-managed hosts), the operator must **confirm the active `glab` account is the correct one** before acting under it — never assume the currently-configured account is the intended one.

This is a **procedure, not a rubric**: run the scripts in order, present, confirm. It is the account analogue of the signing gate in `procedure-git-identity` (that gate is about *who signs*; this one is about *which GitLab login acts*), and the GitLab twin of `procedure-github-auth`.

## The gate (the operator follows this)

1. **Run** `$HOME/.claude/skills/procedure-gitlab-auth/scripts/glab-auth-status.sh` (agent-friendly, non-interactive) to resolve: is `glab` authenticated, as which **account (login)**, on which **host**, and — if several instances are configured — the list.
2. **If not authenticated** (exit 1): do NOT proceed. Ask the user to authenticate (step 4).
3. **If authenticated**: present the active account using **the account report template below** — filled verbatim from the script's machine-parseable `GLAB_*` output — and **ask the user: "is this the correct GitLab login for this operation?"** Proceed only on an explicit "yes".
4. **If the user says no, or is not authenticated: the USER authenticates — the operator does not automate it.** `glab auth login` is inherently interactive (token entry / browser / device code, TTY), so the operator **invokes `$HOME/.claude/skills/procedure-gitlab-auth/scripts/manage_glab_accounts.sh`** (or asks the user to run it via `! …`) and hands the terminal to the user. The user completes the login; the operator does **not** parse or drive that interaction.
5. **Re-verify**: after the interactive script returns, run `$HOME/.claude/skills/procedure-gitlab-auth/scripts/glab-auth-status.sh` again, present the now-active account, and re-confirm. Repeat until the user confirms the correct account, or abort on request.
6. **Only then** perform the GitLab operation.

## The account report (present EXACTLY this at step 3)

Render this block as live Markdown, filled from `glab-auth-status.sh`'s `GLAB_*` lines — substitute each `{KEY}` with that line's value **verbatim**; never reorder, reformat, or drop a row. This fixed shape is what the user confirms against, so it must be deterministic run-to-run:

```markdown
### 🔐 GitLab account — confirm before I act on GitLab

| Field | Value |
|-------|-------|
| Authenticated | {auth_note} |
| Active account | {GLAB_ACTIVE_ACCOUNT} |
| Host | {GLAB_HOST} |
| Other configured accounts | {accounts_note} |

**Is `{GLAB_ACTIVE_ACCOUNT}` on `{GLAB_HOST}` the correct login for this operation?** Reply **yes** to proceed, or **switch**.
```

**Rendering rules for the derived cells (map the exact value → text):**
- `{auth_note}` ← `GLAB_AUTHENTICATED`: `true` → "✅ yes" · `false` → "❌ no (glab installed: {GLAB_INSTALLED})".
- `{accounts_note}` ← `GLAB_ACCOUNTS`: list the configured accounts; if the active one is the only entry, render "— (only this account)".
- If a key's value is empty, render `—` (never invent one).
- **Ambiguity guard:** if `GLAB_ACTIVE_AMBIGUOUS=true` (more than one candidate account — normally one per instance), do **not** present a single account as active — report the ambiguity, list `{GLAB_ACTIVE_ACCOUNTS}`, and re-run `glab-auth-status.sh --hostname <host>` to disambiguate **before** asking for confirmation.
- If `GLAB_AUTHENTICATED=false`: present the block, then route to the interactive script (step 4) — do not ask "yes".

## The two scripts (`$HOME/.claude/skills/procedure-gitlab-auth/scripts/` — both highly portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-gitlab-auth/scripts/<name>`.** Never a bare `scripts/<name>` (it resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from the operator's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the operator runs, so it will not resolve there. Both are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, self-contained (no external library sourcing — not even of the `procedure-github-auth` siblings, whose parsing and render legend are duplicated on purpose), and deterministic. They differ **only** in interaction mode:

**`glab-auth-status.sh`** — **agent-friendly** (non-interactive, machine-parseable), read-only:

```
glab-auth-status.sh [--hostname HOST] [-h|--help]
```

- Determines: is `glab` installed + authenticated; the **active account (login)**; the **host** (gitlab.com or a self-managed instance); and, when several instances are configured, the full list.
- Output: a human-readable status block **+ machine-parseable `GLAB_*=` lines** — `GLAB_INSTALLED`, `GLAB_AUTHENTICATED`, `GLAB_ACTIVE_ACCOUNT`, `GLAB_HOST`, `GLAB_ACCOUNTS`, `GLAB_ACTIVE_AMBIGUOUS`, `GLAB_ACTIVE_ACCOUNTS` — on stdout; diagnostics on stderr.
- **`--hostname HOST` is the disambiguator** — spelled the way `glab auth status` itself spells it (gh's equivalent flag is `--host`; glab's is `--hostname`, so this script takes `--hostname` and **rejects `--host`** rather than inventing an alias glab does not have).
- **Never guesses.** The account is per instance; with more than one candidate and no `--hostname`, it reports `GLAB_ACTIVE_AMBIGUOUS=true`, lists the candidates, leaves `GLAB_ACTIVE_ACCOUNT`/`GLAB_HOST` **empty**, and exits 1. An output-order-dependent guess could present a plausible-but-wrong account to confirm.
- Exit codes: `0` = authenticated with a single resolved account (ready) · `1` = glab absent / not authenticated / no account / ambiguous · `2` = usage error. Deterministic: same `glab` state → same result. Guards `command -v glab`; if `glab` is absent, a clear failure with the install hint.

**`manage_glab_accounts.sh`** — **USER-interactive** (a human drives it; the operator only invokes it and hands over the TTY):

```
manage_glab_accounts.sh [-h|--help]
```

- Shows the current auth state, then offers: **authenticate a specific instance** (pick one of the configured hosts, or type a new hostname → `glab auth login --hostname <h>`) · **log in with glab's own interactive host detection** (`glab auth login`, which suggests instances from the repo's git remotes) · **keep the current account**.
- **There is deliberately no "switch account" row.** `glab auth` has no `switch` subcommand (verified against glab 1.112.0: it offers only `configure-docker`, `docker-helper`, `dpop-gen`, `login`, `logout`, `status`) and glab keeps **one credential per instance**, so there is no glab state that "switching" could set. Authenticating the instance *is* the switch, and choosing among several configured accounts is `glab-auth-status.sh --hostname HOST` — not a mutation here. This is the one structural divergence from `manage_gh_accounts.sh`, whose menu leads with `gh auth switch --user`.
- Deterministic control flow (well-defined menu/branches; no undefined behavior); portable POSIX; **self-contained**; `shellcheck`-clean; supports gitlab.com and self-managed instances. A user-typed hostname is validated against an allow-list before it becomes an argv token.
- Exit `0` = a login completed (or the user chose to keep the current account) · `1` = error / user cancelled. The operator never parses its output — it re-runs `glab-auth-status.sh` afterward to learn the result.

## Constraints (NEVER violate)
- Never run a GitLab operation without a green `glab-auth-status.sh` **and** the user's confirmation that the active account is correct.
- Never automate the interactive login — hand the terminal to the user (invoke the interactive script; do not fake TTY input).
- Never assume the currently-configured account is the intended one — always confirm.
- Never present one of several candidate accounts as "the" active one — resolve with `--hostname` first.
- The status script is read-only; neither script modifies repo state.
- Never create a real GitLab login while developing/testing these scripts — the test suite is fully stubbed (`tests/run-tests.sh`) and must stay that way; no real `glab`, no network.

---
*Procedure Version: 1.0 — the GitLab-account auth gate. Bound by the git-operator AND the project-manager (two domain-agent consumers, the same placement test procedure-github-auth sets — see that skill's description); the signing-identity gate is the separate procedure-git-identity; the MR mechanics are procedure-glab-mr, the issue mechanics procedure-glab-issues. Sibling of procedure-github-auth (same gate shape, different CLI — and glab has no `auth switch`, so no switch action here). Wraps `$HOME/.claude/skills/procedure-gitlab-auth/scripts/`glab-auth-status.sh (agent-friendly) + manage_glab_accounts.sh (user-interactive), both portable POSIX built by the shell tech-pair.*
