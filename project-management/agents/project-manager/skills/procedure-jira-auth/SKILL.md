---
name: procedure-jira-auth
description: The procedure the project-manager runs to confirm the correct Jira Cloud SITE + ACCOUNT before any Jira write, and to hand the engine its credential — the Jira analog of procedure-github-auth's / procedure-gitlab-auth's account gates. It wraps four highly-portable, deterministic scripts — scripts/jira-login.sh (USER-interactive: prompts site+email+API-token, stores a secure per-site 600 credential file; the token is read with terminal echo OFF and never touches argv), scripts/jira-auth-status.sh (agent-friendly, non-interactive, READ-ONLY: reports whether a credential is configured, the configured sites, the default, and the account EMAIL for a site — never the token), scripts/jira-curl-config.sh (non-interactive: resolves a confirmed site's stored credential into the curl-config file PATH the engine consumes via $JIRA_CURL_CONFIG — prints only a path, never the token; fails closed if the site has no credential), and scripts/jira-accounts.sh (list / default / set-default / remove — manage which of several sites is the default). Before any Jira write the caller resolves the active site+account, presents it, and asks the user to confirm it is the right site+login; only then does it resolve $JIRA_CURL_CONFIG and pass the confirmed host to the engine's `--confirmed-site`. It does NOT define artifact craft/content (standard-jira-artifacts) or the Jira REST engine + its commands (procedure-jira — the separate consumer of the $JIRA_CURL_CONFIG handoff this skill produces). This skill is consumed by two callers — the project-manager agent (its original owner) and deploy/hub/hub-accounts.sh (the Crucible Management Hub's Accounts capability, which calls these scripts directly by path) — but unlike procedure-github-auth / procedure-gitlab-auth (both genuinely cross-domain, since git-operator AND project-manager each need one or both of them), Jira auth has exactly one domain consumer, so this skill correctly stays nested inside project-management/agents/project-manager/skills/ rather than living in the top-level, cross-domain accounts/ folder.
---

# Procedure: Jira Site + Account Auth Gate

The **one** gate every Jira write (create / comment / transition / update) passes first. Because a user commonly holds credentials for several Jira Cloud sites at once (e.g. one per client), the caller must **confirm the active site AND account are the intended ones** before writing under them — never assume the default site is the right one. Sending one client's ticket content to another client's Jira is the exact failure this gate exists to stop.

This is a **procedure, not a rubric**: run the scripts in order, present, confirm, hand off the credential. It is the Jira analog of `procedure-github-auth`/`procedure-gitlab-auth` (those gates confirm *which GitHub/GitLab login acts*; this one confirms *which Jira site + account acts*, and additionally produces the credential handoff the engine consumes).

Jira has no local CLI session to switch (no `gh` equivalent), so credentials are a **secure per-site file** this skill writes and resolves; the `procedure-jira` engine is the sole caller of the Jira API and receives the secret only as the `$JIRA_CURL_CONFIG` file path (the handoff interface is fixed before its consumer exists).

## The gate (the caller follows this, before any Jira write)

1. **Run** `$HOME/.claude/skills/procedure-jira-auth/scripts/jira-auth-status.sh [--site SITE]` (agent-friendly, non-interactive, read-only) to resolve: is any credential configured; the configured sites; the default; and, for the resolved site, whether a credential exists and which **account email** it belongs to. The token is never read or printed.
2. **If nothing is configured for the resolved site** (exit 1): do NOT proceed. The user sets up a credential (step 4).
3. **If a credential resolves**: present the active **site + account** using **the site + account report template below** — filled verbatim from the script's `JIRA_AUTH_*` output — and **ask the user: "is this the correct site AND login for this operation?"** Proceed only on an explicit "yes". When the wrong site is the default, the user switches it with `jira-accounts.sh set-default --site SITE` (or the caller passes `--site` to target another configured site directly).
4. **If not configured, or the user wants a different/new account: the USER drives it — the caller does not automate credential entry.** Token entry is inherently interactive (no-echo prompt), so the caller **invokes `$HOME/.claude/skills/procedure-jira-auth/scripts/jira-login.sh [--site SITE]`** and hands the terminal to the user; the caller never parses or drives that prompt. To only change which existing site is the default (no new token), use `jira-accounts.sh set-default`.
5. **Re-verify**: after the interactive step returns, run `jira-auth-status.sh` again, present the now-active site+account, and re-confirm. Repeat until the user confirms, or abort on request.
6. **Resolve the credential handoff** — once the site is confirmed, run `$HOME/.claude/skills/procedure-jira-auth/scripts/jira-curl-config.sh --site <confirmed-host>` and **export its printed path as `JIRA_CURL_CONFIG`**; it prints only a file path, never the token, and fails closed if the confirmed site has no credential.
7. **Only then** invoke the `procedure-jira` engine, passing the confirmed host to **`--confirmed-site <host>`** (the same value) with `JIRA_CURL_CONFIG` set.

## The site + account report (present EXACTLY this at step 3)

Render this block as live Markdown, filled from `jira-auth-status.sh`'s `JIRA_AUTH_*` lines — substitute each `{KEY}` with that line's value **verbatim**; never reorder, reformat, or drop a row. This fixed shape is what the user confirms against, so it must be deterministic run-to-run — the Jira analog of `procedure-github-auth`'s/`procedure-gitlab-auth`'s "account report" block. The same template is used wherever the gate is presented: `flow-project-management` P5 step 1, and a `transition`'s pre-P4 gate.

```markdown
### 🔐 Jira site + account — confirm before I write to Jira

| Field | Value |
|-------|-------|
| Writing under (site) | {JIRA_AUTH_SITE} |
| Account | {JIRA_AUTH_ACCOUNT} |
| Default site | {JIRA_AUTH_DEFAULT_SITE} |
| All configured sites | {JIRA_AUTH_SITES} |

**Is `{JIRA_AUTH_ACCOUNT}` on `{JIRA_AUTH_SITE}` the correct site AND login for this operation?** Reply **yes** to proceed, or **switch**.
```

**Rendering rules for the derived cells (map the exact value → text):**
- `{JIRA_AUTH_SITE}` is the site actually being written under (the resolved `--site`, or the default). If it differs from `{JIRA_AUTH_DEFAULT_SITE}`, that is expected — the user targeted a non-default site — not a reason to skip the confirm.
- `{JIRA_AUTH_DEFAULT_SITE}` — if empty, render `— (no default set)`.
- `{JIRA_AUTH_SITES}` — the comma-separated list; if it holds only `{JIRA_AUTH_SITE}`, render `— (only this site)`.
- If any key's value is empty, render `—` (never invent one).
- If `JIRA_AUTH_SITE_CONFIGURED=false` (no credential for the resolved site — exit 1): do **not** ask "yes"; route to the interactive `jira-login.sh` (step 4) to store one, then re-run status and re-present this block.

## The credential-handoff contract (what this skill produces for `procedure-jira`)

The **interface** by which the engine receives the secret is fixed: `procedure-jira-auth` stores a `600` curl-config file (`user = "email:token"`) per site under a private `700` directory, and `jira-curl-config.sh --site <host>` resolves the confirmed site to that file's **path**. The engine calls `curl -K <that path>` and never asks how it got there. Two forms:

- **Default (no `--copy`)** — prints the path of the **persistent** stored credential file. The engine treats an externally-supplied `$JIRA_CURL_CONFIG` as "not its own" and never deletes it; the caller must NOT delete it either.
- **`--copy`** — prints the path of a fresh `600` `mktemp` **throwaway copy** (useful for isolation from a concurrent `jira-login.sh` overwrite). The **caller owns cleanup** — `rm -f` it as soon as the engine is done (ideally under the caller's own exit trap); it lives in `$TMPDIR`, not the `700` credential dir. Prefer the default unless a disposable file is actually required.

## Secure storage

- **Token off argv, off stdout, off logs.** `jira-login.sh` reads the token with terminal echo OFF (`stty -echo`, restored via a trap even on Ctrl-C); the token never appears on argv, in a prompt echo, in stdout/stderr, or any log. The status/config/accounts scripts never read or print the token — only account emails, site names, and file paths.
- **At rest: a `600` file under a `700` directory** — `${JIRA_CRED_DIR:-$HOME/.claude/crucible/jira/credentials}/<site>.cfg`, one file per site, written via `mktemp` (`umask 077`) then atomically renamed into place (no TOCTOU window, no partial file at the final path). **NEVER `~/.claude/settings.json`, never argv.** (OS-keychain integration is a documented future enhancement, not a silent downgrade — the `600` file is the portable default across macOS/Linux.)
- The host of any stored/confirmed site is validated against the same host-shape allow-list the engine enforces at call time, so a credential can never be stored for a host the engine would refuse.

## The four scripts (`$HOME/.claude/skills/procedure-jira-auth/scripts/` — all portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-jira-auth/scripts/<name>`.** Never a bare `scripts/<name>` (it resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from the caller's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the caller runs. All four are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, self-contained (no external sourcing), and deterministic.

**`jira-auth-status.sh`** — **agent-friendly** (non-interactive, machine-parseable), read-only. `[--site SITE]`. Emits (always, even on failure) `JIRA_AUTH_CONFIGURED`, `JIRA_AUTH_SITES`, `JIRA_AUTH_DEFAULT_SITE`, `JIRA_AUTH_SITE`, `JIRA_AUTH_SITE_CONFIGURED`, `JIRA_AUTH_ACCOUNT` (the email). The token never appears. Exit `0` a credential is configured for the resolved site (ready to present) · `1` no store / no credential for the site / no `--site` and no default · `2` usage.

**`jira-login.sh`** — **USER-interactive** (a human drives it; the caller only invokes and hands over the TTY), the credential writer. `[--site SITE]`. Prompts site + email + API token (token no-echo), stores the secure per-site `600` file. The FIRST site stored becomes the default. **Never calls Jira** — it only writes the credential file. Exit `0` stored (or reused unchanged) · `1` error/cancelled · `2` usage.

**`jira-curl-config.sh`** — **non-interactive**, agent-friendly, the handoff resolver. `--site SITE [--copy]`. Prints the curl-config file **path** (persistent, or a `--copy` throwaway) for `$JIRA_CURL_CONFIG`; never the token. **Fails closed** if the site has no credential — never falls back to another site. Exit `0` path printed · `1` no credential for SITE / filesystem error · `2` usage.

**`jira-accounts.sh`** — **non-interactive**, agent-friendly, the multi-site manager. `list [--json]` · `default` · `set-default --site SITE` · `remove --site SITE --force`. Manages which configured site is the default that `jira-auth-status.sh`/`jira-curl-config.sh` resolve to when no `--site` is given. `set-default` fails closed if SITE has no credential; `remove` is destructive (requires `--force`) and clears the default marker if it removed the default. Touches only file names + the default marker, never token contents. Exit `0` · `1` not configured / no default / filesystem error · `2` usage (unknown subcommand, missing `--site`, `remove` without `--force`).

## Constraints (NEVER violate)

- Never run a Jira write without a green `jira-auth-status.sh` **and** the user's confirmation that the active **site AND account** are correct — the two-client failure is the reason this gate exists.
- Never automate the interactive credential entry — hand the terminal to the user (invoke `jira-login.sh`; never fake TTY input or type the token).
- Never assume the default site is the intended one — always confirm; a user holds several sites at once.
- Never surface, log, or pass the token — the engine receives only the `$JIRA_CURL_CONFIG` **path** from `jira-curl-config.sh`; three of the four scripts never read the token at all.
- Never store a credential anywhere but the `600`-file-under-`700`-dir store — never `settings.json`, never argv.
- `jira-auth-status.sh` / `jira-curl-config.sh` / `jira-accounts.sh` are non-interactive and never prompt; only `jira-login.sh` is interactive. The caller re-runs `jira-auth-status.sh` to learn an interactive step's result — it never parses `jira-login.sh`'s output.

---
*Procedure Version: 1.1 — the Jira site + account auth gate and the engine credential handoff. 1.1 adds the fixed "site + account report" presentation template (the deterministic analog of procedure-github-auth's account-report block, filled verbatim from the JIRA_AUTH_* keys), referenced by the gate's step 3 and by flow-project-management's P5 / transition pre-P4 gate. Bound by the project-manager; the Jira REST engine it gates + hands off to is the separate `procedure-jira` (consumer of `$JIRA_CURL_CONFIG`); artifact craft/content is `standard-jira-artifacts`. Wraps `$HOME/.claude/skills/procedure-jira-auth/scripts/`jira-login.sh (user-interactive) + jira-auth-status.sh (agent-friendly, read-only) + jira-curl-config.sh (handoff resolver) + jira-accounts.sh (multi-site default manager) — all portable POSIX, shellcheck-clean, self-contained.*
