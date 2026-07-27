---
name: procedure-git-identity
description: The single definition of how the git-operator resolves, reconciles, and CONFIRMS the signing identity before any commit or signed tag. Applies before every commit and every signed tag. It wraps a small suite of deterministic, highly-portable shell scripts (scripts/: resolve, list, switch identity) that programmatically pinpoint the committer identity, the signing key (GPG or SSH), and the Signed-off-by it will write, assert they agree, and — if the user rejects the proposal — deterministically list and switch to another identity/key. The operator presents the resolved identity for the user's explicit confirmation before committing, and never improvises git commands for identity/signing. It does NOT define commit format (standard-git-commit) or tag policy (standard-git-tag); those bind this skill for the signing/identity gate.
---

# Procedure: Git Signing Identity

The **one** gate every commit and signed tag passes first. A signature and a `Signed-off-by` are only meaningful if the **committer identity, the signing key, and the sign-off are one consistent, reconciled identity** — this skill makes that deterministic and requires the user's confirmation.

## The four fields that must reconcile

For a commit to be both **"Verified"** on GitHub and validly signed-off, these must agree:

1. **`git config user.email`** — the **committer** email. Must be an email **verified on the GitHub account** (else the commit is unattributed and cannot be "Verified"). This is asserted only when the `--github` query **succeeds**: a `verified` result confirms it and an `unverified` result fails the gate, but an **undetermined (`unknown`) or `skipped`** check leaves the question unasked and **does not fail the gate**.
2. **The signing key's email** — the GPG key's UID email, or the SSH allowed-signers entry — must match (1).
3. **`Signed-off-by:` email** — the DCO footer the commit will carry — must match (1).
4. **Committer vs author** — distinct; if they differ (applying someone else's patch), that is surfaced explicitly so it is intentional, not accidental (a mismatch downgrades the badge to "Partially verified").

Signing method is **GPG or SSH** — both earn "Verified"; the script handles whichever `gpg.format` is configured. (Sigstore/`gitsign` is CI-only today — GitHub shows it "Unverified".)

Enable **Vigilant Mode** on the account so *unsigned* commits are flagged "Unverified" rather than passing unmarked (account-scope — complements the repo ruleset's "require signed commits"). Maintain a **`.mailmap`** to canonicalize author/committer names + emails in `git log`/`shortlog` — it complements this identity discipline.

## The procedure (the operator follows this)

1. **Run** `$HOME/.claude/skills/procedure-git-identity/scripts/resolve-identity.sh --github` from the repository. It reads the git config + key material and reconciles the fields above — no guessing by the model. **Always pass `--github`** — it is what surfaces an unattributable committer email, and it cannot block you spuriously: only a query that *succeeded and answered no* is fatal (`unverified`); a query that could not run is a notice (`unknown`/`skipped`, exit 0). Do not decide for yourself whether to include the flag.
2. **If it exits non-zero** (field mismatch, missing/misconfigured signing key, or a `--github` check that returned a real negative), STOP — do not commit. Report exactly what failed and what the user must fix. Branch on the **exit status**, never on how a state's name reads: a check that could not run exits `0` and is a notice, not a stop.
3. **If it exits zero**, present the resolved identity using **the report template below** — filled verbatim from the script's machine-parseable `IDENTITY_*` output — and **ask the user to confirm this is the identity + key to use.**
4. **If the user does NOT approve** the proposed identity and/or signing key, do NOT commit — **switch using the scripts** (never by improvising git commands):
   - Run **`$HOME/.claude/skills/procedure-git-identity/scripts/list-identities.sh`** to enumerate the available signing identities/keys (GPG secret keys + SSH signing keys) and present the choices.
   - Once the user picks, run **`$HOME/.claude/skills/procedure-git-identity/scripts/switch-identity.sh`** to apply it deterministically (repo-local by default; `--scope global` to persist).
   - Re-run **`$HOME/.claude/skills/procedure-git-identity/scripts/resolve-identity.sh --github`** to confirm the new selection reconciles, then present it again for confirmation. The re-check carries `--github` too — a switch changes the committer email, so it is exactly when the GitHub question needs re-asking.
   - Repeat until the user confirms, or abort on request. Never commit with an identity/key the user did not approve.
5. **Commit only after the user confirms.** This confirmation gate is mandatory (the user's rule); it is never skipped or assumed.

## The identity report (present EXACTLY this at step 3)

Render this block as live Markdown, filled from `resolve-identity.sh`'s `IDENTITY_*` lines — substitute each `{KEY}` with that line's value **verbatim**; never reorder, reformat, or drop a row. This fixed shape is what the user confirms against, so it must be deterministic run-to-run:

```markdown
### 🔑 Signing identity — confirm before I commit

| Field | Value |
|-------|-------|
| Name | {IDENTITY_NAME} |
| Committer email | {IDENTITY_COMMITTER_EMAIL} — {github_note} |
| Signing method | {IDENTITY_SIGNING_METHOD} |
| Signing key | {IDENTITY_SIGNING_KEY_ID} · {IDENTITY_SIGNING_KEY_FPR} |
| Sign-off | {IDENTITY_SIGNOFF} |
| Author vs committer | {author_note} |

**Reconciliation:** {reconciliation_note}

{github_unknown_notice}

**Commit under this identity?** Reply **yes** to proceed, or **switch** to choose another.
```

**Rendering rules for the derived cells (map the exact value → text):**
- `{github_note}` ← `IDENTITY_GITHUB`: `verified` → "✅ GitHub-verified" · `unverified` → "⚠️ NOT GitHub-verified" · `unknown` → "❓ GitHub verification undetermined (the check could not run — not a failure)" · `skipped` → "ℹ️ GitHub check skipped (gh absent or unauthenticated)".
- `{author_note}` ← `IDENTITY_AUTHOR_COMMITTER_MATCH`: `true` → "✅ author = committer" · `false` → "⚠️ author {IDENTITY_AUTHOR_EMAIL} ≠ committer — applying another's patch".
- `{reconciliation_note}` ← `IDENTITY_STATUS`: `reconciled` → "✅ committer = signing-key = sign-off — consistent" · `mismatch` **with `IDENTITY_GITHUB=unverified`** → "❌ committer email is not GitHub-verified — I will NOT commit" (the three git-local fields DO agree here; naming them as the cause misreports it) · `mismatch` otherwise → "❌ fields disagree — I will NOT commit".
- If a key's value is empty, render `—` (never invent one). If `IDENTITY_STATUS=mismatch` **or** the script exited non-zero: present the block, name the failing field, and STOP — do **not** offer "yes".
- `{github_unknown_notice}` ← `IDENTITY_GITHUB`: `verified`/`unverified`/`skipped` → render **empty** (the line disappears) · `unknown` → the prose notice below. It is a placeholder precisely because it is the one element guarding a fail-open: every other derived cell is wired into the fixed template, and the notice must be too.
- **`IDENTITY_GITHUB=unknown` — surface it in PROSE, never only as a table glyph.** The commit is *not* blocked and `{reconciliation_note}` will still read "consistent", so the ❓ cell alone is too quiet to be the sole notice on a fail-open. Render `{github_unknown_notice}` as one sentence naming what went unchecked and relaying the script's remedy **verbatim**, e.g.: "⚠️ I could not confirm this email is GitHub-verified (`gh api user/emails` failed — candidate causes: the token lacks the `user` OAuth scope, a network failure, or a rate limit). If it is the scope, fix it with `gh auth refresh -h github.com -s user`. This does not block the commit." **Relay the script's second warning line (`gh reported: …`) too when it emitted one — that is gh's own message and names the real cause.** Then still offer **yes** — this is a notice, never a gate. Repeat it on every commit while the state persists; a permanently-scoped-out token must not go quiet.

## The script suite (`$HOME/.claude/skills/procedure-git-identity/scripts/` — deterministic & portable)

All identity operations run through these scripts — the operator **never improvises git commands** for identity/signing. **Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-git-identity/scripts/<name>`.** Never a bare `scripts/<name>` (it resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from the operator's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the operator runs, so it will not resolve there. All are **highly portable** (POSIX `sh`, any machine with `git` + a signing tool), **deterministic**, and `shellcheck`-clean; all are read-only **except `switch-identity.sh`, which writes only git config** (never keys or the repo tree).

**`resolve-identity.sh`** `[--email/--name/--signingkey/--format]` `[--github]` — reconcile & report (read-only):
- Reads `git config user.name/user.email/user.signingkey/gpg.format` (default `openpgp`), the committer/author identity, and the key material — GPG (`gpg --list-secret-keys`) or SSH (`gpg.ssh.allowedSignersFile`).
- **Override flags** reconcile a SPECIFIED identity instead of the configured one (used to re-verify a switched choice), still read-only.
- Reconciles fields 1–3; surfaces field 4 (author≠committer) as a warning.
- **`--github`** (optional): if `gh` is present + authenticated, also verify `user.email` is a **GitHub-verified** address (`gh api user/emails`). Four states, and **only `unverified` is fatal**: `verified` (query succeeded, email listed) · `unverified` (query **succeeded** and did not list it — a real negative, exit 1) · `unknown` (the query **failed** — missing `user` OAuth scope, network, rate limit — **notice, never fail**; remedy: `gh auth refresh -h github.com -s user`) · `skipped` (gh absent/unauthenticated — **notice, never fail**). A question that could not be asked is never answered "no"; the git-local checks always run regardless.
- Output: human-readable identity block **+ machine-parseable `KEY=VALUE`** on stdout; diagnostics on stderr. Exit `0` reconciled · `1` mismatch/misconfig · `2` usage.

**`list-identities.sh`** — enumerate available signing identities so the user can choose (read-only):
- Lists GPG secret keys (key id, fingerprint, UID name + email) and SSH signing keys, in a **stable, deterministic order**.
- Output: a numbered human-readable list + a machine-parseable form. Exit `0`, or `1` if none found.

**`switch-identity.sh`** `--email <e> --name <n> --signingkey <k>` `[--format gpg|ssh]` `[--scope repo|global]` — deterministically APPLY a chosen identity/key:
- Sets `user.name/user.email/user.signingkey/gpg.format` via `git config` — **`--scope repo` (default, local)** or `--scope global`. Validates the key exists before setting; **idempotent** (same args → same config).
- Exit `0` applied · `1` invalid/missing key · `2` usage. The operator then re-runs `resolve-identity.sh --github` to confirm.

**Shared portability contract:** POSIX `sh` only (no bashisms), macOS (BSD / Bash 3.2) **and** Linux, `shellcheck`-clean, `command -v` guards for every external binary, graceful degradation when `gh`/gpg/ssh is absent. Each script ships with portable tests (see `tests/`).

## Constraints (NEVER violate)
- Never commit or cut a signed tag without a green run of the script **and** the user's confirmation.
- Never proceed on a field mismatch, a missing signing key, or an author≠committer divergence the user hasn't acknowledged.
- The script never modifies git config or the repo — it only reads and reports.

---
*Standard Version: 1.0 — the shared signing-identity gate. Bound (for signing) by standard-git-commit and standard-git-tag; executed by the git-operator. Wraps `$HOME/.claude/skills/procedure-git-identity/scripts/`{resolve,list,switch}-identity.sh (portable POSIX, built by the shell tech-pair).*
