---
name: procedure-git-auth
description: The procedure the git-operator runs to confirm the correct GitHub CLI ACCOUNT before any GitHub operation (open/update a PR, cut a release). It wraps two highly-portable, deterministic scripts — scripts/gh-auth-status.sh (agent-friendly, non-interactive: reports whether gh is authenticated and exactly which account + host) and scripts/manage_gh_accounts.sh (USER-interactive: the human switches/logs in). Before any gh action the operator resolves the active account, presents it, and asks the user to confirm it is the right login; if not, the USER switches via the interactive script and the operator re-verifies. It does NOT define commit/branch/PR/tag conventions (the standard-git-* skills) or the signing identity (procedure-git-identity — the separate signing gate).
---

# Procedure: Git/GitHub Account Auth Gate

The **one** gate every GitHub operation (open/update a PR, cut a release) passes first. Because a user commonly switches between GitHub profiles, the operator must **confirm the active `gh` account is the correct one** before acting under it — never assume the currently-logged-in account is the intended one.

This is a **procedure, not a rubric**: run the scripts in order, present, confirm. It is the account analogue of the signing gate in `procedure-git-identity` (that gate is about *who signs*; this one is about *which GitHub login acts*).

## The gate (the operator follows this)

1. **Run** `$HOME/.claude/skills/procedure-git-auth/scripts/gh-auth-status.sh` (agent-friendly, non-interactive) to resolve: is `gh` authenticated, as which **account (login)**, on which **host**, and — if several are logged in — the list + which is active.
2. **If not authenticated** (exit 1): do NOT proceed. Ask the user to authenticate (step 4).
3. **If authenticated**: present the active account using **the account report template below** — filled verbatim from the script's machine-parseable `GH_*` output — and **ask the user: "is this the correct GitHub login for this operation?"** Proceed only on an explicit "yes".
4. **If the user says no, or is not authenticated: the USER switches — the operator does not automate it.** `gh auth login` / account-switching is inherently interactive (browser/device-code, TTY), so the operator **invokes `$HOME/.claude/skills/procedure-git-auth/scripts/manage_gh_accounts.sh`** (or asks the user to run it via `! …`) and hands the terminal to the user. The user completes the switch/login; the operator does **not** parse or drive that interaction.
5. **Re-verify**: after the interactive switch returns, run `$HOME/.claude/skills/procedure-git-auth/scripts/gh-auth-status.sh` again, present the now-active account, and re-confirm. Repeat until the user confirms the correct account, or abort on request.
6. **Only then** perform the GitHub operation.

## The account report (present EXACTLY this at step 3)

Render this block as live Markdown, filled from `gh-auth-status.sh`'s `GH_*` lines — substitute each `{KEY}` with that line's value **verbatim**; never reorder, reformat, or drop a row. This fixed shape is what the user confirms against, so it must be deterministic run-to-run:

```markdown
### 🔐 GitHub account — confirm before I act on GitHub

| Field | Value |
|-------|-------|
| Authenticated | {auth_note} |
| Active account | {GH_ACTIVE_ACCOUNT} |
| Host | {GH_HOST} |
| Other logged-in accounts | {accounts_note} |

**Is `{GH_ACTIVE_ACCOUNT}` on `{GH_HOST}` the correct login for this operation?** Reply **yes** to proceed, or **switch**.
```

**Rendering rules for the derived cells (map the exact value → text):**
- `{auth_note}` ← `GH_AUTHENTICATED`: `true` → "✅ yes" · `false` → "❌ no (gh installed: {GH_INSTALLED})".
- `{accounts_note}` ← `GH_ACCOUNTS`: list the logged-in accounts; if the active one is the only entry, render "— (only this account)".
- If a key's value is empty, render `—` (never invent one).
- **Ambiguity guard:** if `GH_ACTIVE_AMBIGUOUS=true` (more than one host has an active account), do **not** present a single account as active — report the ambiguity, list `{GH_ACTIVE_ACCOUNTS}`, and re-run `gh-auth-status.sh --host <host>` to disambiguate **before** asking for confirmation.
- If `GH_AUTHENTICATED=false`: present the block, then route to the interactive switch (step 4) — do not ask "yes".

## The two scripts (`$HOME/.claude/skills/procedure-git-auth/scripts/` — both highly portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-git-auth/scripts/<name>`.** Never a bare `scripts/<name>` (it resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from the operator's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the operator runs, so it will not resolve there. Both are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, self-contained (no external library sourcing), and deterministic. They differ **only** in interaction mode:

**`gh-auth-status.sh`** — **agent-friendly** (non-interactive, machine-parseable), read-only:
- Determines: is `gh` installed + authenticated; the **active account (login)**; the **host** (github.com or an Enterprise host); and, if multiple accounts are logged in, the full list with the active one marked.
- Output: a human-readable status block **+ machine-parseable `GH_*=` lines** (e.g. `GH_AUTHENTICATED=`, `GH_ACTIVE_ACCOUNT=`, `GH_HOST=`, `GH_ACCOUNTS=`) on stdout; diagnostics on stderr.
- Exit codes: `0` = authenticated (ready) · `1` = not authenticated / no active account · `2` = usage error. Deterministic: same `gh` state → same result. Guards `command -v gh`; if `gh` is absent, a clear failure with the install hint.

**`manage_gh_accounts.sh`** — **USER-interactive** (a human drives it; the operator only invokes it and hands over the TTY), the switcher:
- Guides the user to **switch** to another already-logged-in account (prefer `gh auth switch --user … --hostname …` — non-interactive and fast where the account is already authenticated) or to **log in** a new account (`gh auth login`, inherently interactive).
- Deterministic control flow (well-defined menu/branches; no undefined behavior); portable POSIX; **self-contained** (no sourcing of external `common/lib/*.sh` — inline what it needs); `shellcheck`-clean; supports github.com and Enterprise hosts.
- Exit `0` = a switch/login completed (or the user chose to keep the current account) · `1` = error / user cancelled. The operator never parses its output — it re-runs `gh-auth-status.sh` afterward to learn the result.

*(The starting point for the switcher is the user's existing `manage_gh_accounts.sh` in the control-center-infra repo — it is polished to this bar: made self-contained + portable, kept user-interactive.)*

## Constraints (NEVER violate)
- Never run a GitHub operation without a green `gh-auth-status.sh` **and** the user's confirmation that the active account is correct.
- Never automate the interactive login/switch — hand the terminal to the user (invoke the interactive script; do not fake TTY input).
- Never assume the currently-logged-in account is the intended one — always confirm.
- The status script is read-only; neither script modifies repo state.

---
*Procedure Version: 1.0 — the GitHub-account auth gate. Bound by the git-operator; the signing-identity gate is the separate procedure-git-identity. Wraps `$HOME/.claude/skills/procedure-git-auth/scripts/`gh-auth-status.sh (agent-friendly) + manage_gh_accounts.sh (user-interactive), both portable POSIX built/polished by the shell tech-pair.*
