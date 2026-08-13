---
name: procedure-jira-auth
description: Confirms the correct Jira Cloud site + account, with explicit user confirmation, and hands off the resolved credential — required before the procedure-jira engine can be invoked. Does NOT define artifact craft/content (standard-jira-artifacts) or the Jira REST engine + its commands (procedure-jira).
---

# Procedure: Jira Site + Account Auth Gate

The **one** gate every Jira write (create / comment / transition / update) passes first. Because a user commonly holds credentials for several Jira Cloud sites at once (e.g. one per client), the caller must **confirm the active site AND account are the intended ones** before writing under them — never assume the default site is the right one. Sending one client's ticket content to another client's Jira is the exact failure this gate exists to stop.

This is a **procedure, not a rubric**: run the scripts in order, present, confirm, hand off the credential. It is the Jira analog of `procedure-github-auth`/`procedure-gitlab-auth` (those gates confirm *which GitHub/GitLab login acts*; this one confirms *which Jira site + account acts*, and additionally produces the credential handoff the engine consumes).

Jira has no local CLI session to switch (no `gh` equivalent), so credentials are a **secure per-site file** this skill writes and resolves; the `procedure-jira` engine is the sole caller of the Jira API and receives the secret only as the `$JIRA_CURL_CONFIG` file path (the handoff interface is fixed before its consumer exists).

## The gate (the caller follows this, before any Jira write)

1. **Run** `$HOME/.claude/skills/procedure-jira-auth/scripts/jira-auth-status.sh [--site SITE]` (agent-friendly, non-interactive, read-only) to resolve: is any credential configured; the configured sites; the default; and, for the resolved site, whether a credential exists and which **account email** it belongs to. The token is never read or printed.
2. **If nothing is configured for the resolved site** (exit 1): do NOT proceed. The user sets up a credential (step 4).
3. **If a credential resolves**: present the active **site + account** using **the matching report template below** — the **write-framed** one (present before P4/P5, when the imminent action is a live write) or the **read-framed** one (present before P2's analysis, when the imminent action is a read-only lookup) — filled verbatim from the script's `JIRA_AUTH_*` output, and **ask the user to confirm it is the correct site AND login for THAT operation** (the template's own question names which). Proceed only on an explicit "yes". When the wrong site is the default, the user switches it with `jira-accounts.sh set-default --site SITE` (or the caller passes `--site` to target another configured site directly). **Presenting the wrong-framed template — a write-framed confirmation for a read, or vice versa — risks the human treating one "yes" as consent for both**; use the one that matches what is about to happen.
4. **If not configured, or the user wants a different/new account: the USER drives it — the caller does not automate credential entry.** Token entry is inherently interactive (no-echo prompt), so the caller **invokes `$HOME/.claude/skills/procedure-jira-auth/scripts/jira-login.sh [--site SITE]`** and hands the terminal to the user; the caller never parses or drives that prompt. To only change which existing site is the default (no new token), use `jira-accounts.sh set-default`.
5. **Re-verify**: after the interactive step returns, run `jira-auth-status.sh` again, present the now-active site+account, and re-confirm. Repeat until the user confirms, or abort on request.
6. **Resolve the credential handoff FRESH, immediately before every `jira.sh` call — never carry a resolved path forward across steps or hand one to another process.** `jira-curl-config.sh --site <confirmed-host>` is non-interactive, idempotent, and fails closed — cheap enough to call every single time `$JIRA_CURL_CONFIG` is needed, so nothing downstream ever trusts a REMEMBERED path that could have drifted from the site it was actually resolved for (e.g. a multi-site turn where a later call accidentally reuses an earlier site's path). What crosses a hand-off is the CONFIRMED SITE, never a path:
   - **If YOU (the gate-runner) also call `jira.sh` yourself, in your own process** — run `jira-curl-config.sh --site <confirmed-host>` right before that call, export its printed path as `JIRA_CURL_CONFIG`, and use it immediately. Do not resolve it once and hold it for a later call.
   - **If a SEPARATE subagent calls `jira.sh`** (e.g. the orchestrator ran this gate to dispatch `project-manager`) — an export in your process does NOT cross into that subagent's process, so exporting on its behalf is moot anyway. Hand it ONLY the confirmed **site** as a plain dispatch value — never a path, remembered or otherwise. The subagent resolves its OWN path, itself, by running `jira-curl-config.sh --site <that site>` immediately before each of its own `jira.sh` calls, and exports the result in its own process. Resolving is the consumer's job in every case; a caller never pre-computes it and relays the answer.
7. **Only then** invoke (or dispatch) the `procedure-jira` engine, passing the confirmed host to **`--confirmed-site <host>`** (the same value handed forward in step 6). Every `$JIRA_CURL_CONFIG` in play was resolved fresh, in the same process that is about to use it, from the SAME confirmed site named in this call — never a value carried over from an earlier step or a different site.

## The site + account report — two variants, one for a write, one for a read (present EXACTLY one of these at step 3)

Render whichever block below is live Markdown, filled from `jira-auth-status.sh`'s `JIRA_AUTH_*` lines — substitute each `{KEY}` with that line's value **verbatim**; never reorder, reformat, or drop a row. Both blocks pull from the SAME four keys — only the header, the first row's label, and the confirm question differ, so the underlying values the user is confirming are identical regardless of which variant fires. This fixed shape is what the user confirms against, so each variant must be deterministic run-to-run — the Jira analog of `procedure-github-auth`'s/`procedure-gitlab-auth`'s "account report" block.

**Which variant, where:** the **write** variant is used at `flow-project-management` P5 step 1 (create/comment/a text-bearing update) — the imminent action there IS the write. The **read** variant is used at P2 for any Jira content-less lifecycle op (close/label-add/reassign/transition — regardless of which `jira.sh` command implements it) — the imminent action there is `project-manager`'s own analysis (or the orchestrator's, on the missing-agent exception) making a live READ before any disclosure or consent; the actual write for that op still waits for its own separate consent at P4/P5. **Presenting the write variant at P2 would ask the user to confirm "writing under this site" for what is actually only a read** — a mismatch between the prompt's framing and the real action, risking the human believing this "yes" already covers the later write. Always match the variant to what happens next.

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

```markdown
### 🔎 Jira site + account — confirm before I read from Jira (analysis only — not yet a write)

| Field | Value |
|-------|-------|
| Reading from (site) | {JIRA_AUTH_SITE} |
| Account | {JIRA_AUTH_ACCOUNT} |
| Default site | {JIRA_AUTH_DEFAULT_SITE} |
| All configured sites | {JIRA_AUTH_SITES} |

**Is `{JIRA_AUTH_ACCOUNT}` on `{JIRA_AUTH_SITE}` the correct site AND login for this analysis?** Reply **yes** to proceed, or **switch**. This is a **read-only lookup** — any actual write still needs your separate approval later, at its own consent gate.
```

**Rendering rules for the derived cells (map the exact value → text) — apply identically to both variants:**
- `{JIRA_AUTH_SITE}` is the site actually being written under (the resolved `--site`, or the default). If it differs from `{JIRA_AUTH_DEFAULT_SITE}`, that is expected — the user targeted a non-default site — not a reason to skip the confirm.
- `{JIRA_AUTH_DEFAULT_SITE}` — if empty, render `— (no default set)`.
- `{JIRA_AUTH_SITES}` — the comma-separated list; if it holds only `{JIRA_AUTH_SITE}`, render `— (only this site)`.
- If any key's value is empty, render `—` (never invent one).
- If `JIRA_AUTH_SITE_CONFIGURED=false` (no credential for the resolved site — exit 1): do **not** ask "yes"; route to the interactive `jira-login.sh` (step 4) to store one, then re-run status and re-present this block.

## The credential-handoff contract (what this skill produces for `procedure-jira`)

The **interface** by which the engine receives the secret is fixed: `procedure-jira-auth` stores a `600` curl-config file (`user = "email:token"`) per site under a private `700` directory, and `jira-curl-config.sh --site <host>` resolves the confirmed site to that file's **path**. The engine calls `curl -K <that path>` and never asks how it got there. Two forms:

- **Default (no `--copy`)** — prints the path of the **persistent** stored credential file. The engine treats an externally-supplied `$JIRA_CURL_CONFIG` as "not its own" and never deletes it; the caller must NOT delete it either. **This is the form the "resolve fresh, immediately before every call" rule (above) assumes** — re-running `jira-curl-config.sh --site <host>` every time costs nothing extra, since it just re-prints the SAME persistent path each time; nothing new is created or needs cleanup.
- **`--copy`** — prints the path of a fresh `600` `mktemp` **throwaway copy** (useful for isolation from a concurrent `jira-login.sh` overwrite). The **caller owns cleanup** — `rm -f` it as soon as the engine is done (ideally under the caller's own exit trap); it lives in `$TMPDIR`, not the `700` credential dir. **`--copy` is now INCOMPATIBLE with `procedure-jira`'s engine and must not be used with it**: the engine enforces that an externally-supplied `$JIRA_CURL_CONFIG`'s basename matches `<confirmed-host>.cfg` (its own site-binding check), but a `--copy`'d `mktemp` filename carries no site name at all — the engine will refuse it every time. Use the default (persistent) form exclusively for anything feeding this engine; `--copy` remains available only for a caller outside `procedure-jira` that genuinely needs an isolated, self-cleaned-up throwaway file for some other purpose.

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
*Procedure Version: 1.6 — the SEC-011 code fix 1.5 flagged as deliberately deferred has now landed in `procedure-jira`'s `lib/credentials.sh` (a basename-vs-confirmed-site binding, not `lib/sitegate.sh` as 1.5 guessed). That fix makes `--copy` outright INCOMPATIBLE with the engine — a `--copy`'d `mktemp` filename carries no site name, so the new binding check refuses it every time — so this version updates the `--copy` guidance from "prefer the default, reach for `--copy` only when..." to "never use `--copy` with this engine at all."*
*Procedure Version: 1.5 — a verification pass on 1.4's fix found the `--copy` form's caller-owned-cleanup discipline was never reconciled with the new "resolve fresh before every call" rule — reconciled: the default (persistent) form is what that rule assumes, since re-resolving it just re-prints the same path at no cost; `--copy` must not be combined with per-call resolution, since that mints one throwaway secret-bearing file per call. Also flags SEC-011 (this skill's own guarantee — a resolved path always matches its confirmed site — is enforced by convention here, not by `procedure-jira`'s engine, which cross-checks `--confirmed-site` only against the test-only `$JIRA_SITE` fallback) as a real code change to `lib/sitegate.sh` this version deliberately does NOT make.*
*Procedure Version: 1.4 — a security review of the 1.3 handoff (the literal-path dispatch value added there) found it created a NEW failure mode: a path resolved once at P2 and carried forward through P4/P5, or relayed to a subagent, has nothing checking it still belongs to the site it was confirmed against — a stale or mis-paired path could silently send one client's credential to another client's Jira site. Fixed by eliminating the "remembered path" entirely: step 6 now re-resolves `$JIRA_CURL_CONFIG` FRESH, immediately before every `jira.sh` call, in whichever process is about to make that call — a caller hands forward the confirmed SITE only, never a path, and the consumer (itself or a dispatched subagent) always derives its own path from that site right before use. Since `jira-curl-config.sh` is a pure, non-interactive, idempotent function of `--site`, this costs nothing extra and removes the vulnerability class structurally rather than by convention. Also added a SEPARATE read-framed report template (step 3): the write-framed template was being reused, verbatim, to confirm a read-only lookup at `flow-project-management` P2, asking the user "is this the correct site AND login for this **write**?" before an action that is not yet a write — risking the human treating that "yes" as covering the later write too. The two variants pull from the same four keys; only the header/first-row label/confirm question differ.*
*Procedure Version: 1.3 — step 6 was silent about who calls `jira.sh` next, so it read as always "export and proceed" — true only when the gate-runner and the engine-caller are the same process. Fixed for the case they're not: when the orchestrator runs this gate to dispatch `project-manager`, an export in the orchestrator's process never reaches the subagent's; step 6 now branches explicitly, handing the literal config-file path as a dispatch value in that case. Also corrected the report-template note's phrasing — the live read is made BY `project-manager`'s (or the orchestrator's) analysis, not merely required "before" it — and replaced "create/comment/update" with "create/comment/a text-bearing update" there, since a label-add/reassign is also an `update` call but is content-less and gates at P2, not P5 (the same fix `flow-project-management` 1.9 and `procedure-jira` 2.1 made, applied here too).*
*Procedure Version: 1.2 — updated the gate-position cross-references: a content-less lifecycle op's (close/label-add/reassign/transition, not transition alone) gate now runs at `flow-project-management` P2 (before `project-manager`'s own analysis, or the orchestrator's own on the missing-agent exception), not "pre-P4" — P4/P5 for those ops both reuse the credential resolved there. Create/comment/update keep their gate at P5, unchanged (superseded by 1.3 — a label-add/reassign is also technically an `update` call, but is content-less and gates at P2 instead).*
*Procedure Version: 1.1 — the Jira site + account auth gate and the engine credential handoff. 1.1 adds the fixed "site + account report" presentation template (the deterministic analog of procedure-github-auth's account-report block, filled verbatim from the JIRA_AUTH_* keys), referenced by the gate's step 3 and by flow-project-management's write paths. Bound by the project-manager; the Jira REST engine it gates + hands off to is the separate `procedure-jira` (consumer of `$JIRA_CURL_CONFIG`); artifact craft/content is `standard-jira-artifacts`. Wraps `$HOME/.claude/skills/procedure-jira-auth/scripts/`jira-login.sh (user-interactive) + jira-auth-status.sh (agent-friendly, read-only) + jira-curl-config.sh (handoff resolver) + jira-accounts.sh (multi-site default manager) — all portable POSIX, shellcheck-clean, self-contained.*
