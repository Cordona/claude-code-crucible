---
name: standard-shell-script
description: The single rubric for idiomatic, correct, safe shell — what the shell-script-developer BUILDS to and the shell-script-reviewer REVIEWS against. Applies whenever Bash/POSIX shell is written, changed, or reviewed. Defines only WHAT good shell looks like — not builder workflow (build-core), the reviewer's correctness-detective method, category vocabulary, SC-code scoring, and scope-boundary table (genuinely shell-script-reviewer's own), the base severity scale/handoff mechanism (review-core / review-report-standards), build/report envelopes (build-report-standards / review-report-standards), or the universal cross-cutting standards (standard-clean-code, standard-self-documenting-code, standard-observability, standard-performance, standard-security — their own).
---

# Standard: Shell Script

The **one** definition of what good, correct, safe shell looks like. The `shell-script-developer` builds to it; the `shell-script-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we write shell and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like** — the idioms to reach for and the traps to avoid. It is **NOT a shell tutorial**: assume fluent Bash/POSIX, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: the builder's workflow and validation gate (`build-core` / the developer); the reviewer's correctness-detective method, `category` vocabulary, SC-code scoring, and its own scope-boundary table (genuinely `shell-script-reviewer`'s own); the base severity scale, the handoff mechanism, and universal finding-quality/false-positive discipline (`review-core` / `review-report-standards` — `shell-script-reviewer` only maps its own categories onto that scale); the build/report envelopes (`build-report-standards` / `review-report-standards`); or the universal cross-cutting standards — `standard-clean-code`, `standard-self-documenting-code`, `standard-observability`, `standard-performance`, `standard-security` (their own standards).

Assume **Bash 4+** (`#!/usr/bin/env bash`) unless POSIX `sh` is required — see Portability below for the macOS Bash 3.2 caveat.

## Quoting & Expansion

Shell's #1 correctness and safety surface — most real-world shell defects trace back to a missed quote or an unintended expansion.

- **Quote every expansion**: `"$var"`, `"${array[@]}"`, `"${@}"`, `"$(cmd)"`. An unquoted expansion undergoes **word-splitting + glob expansion**, which changes behavior and opens an injection/word-splitting surface (SC2086; SC2046 on unquoted `$(…)`; SC2068 on unquoted `${arr[@]}`). Splitting does not occur in an assignment RHS (`x=$y`), inside `[[ … ]]`, a `case` word, or `(( … ))` — quotes there are harmless but not required, and their absence is not a defect.
- **Build commands as arrays, never as strings** — `cmd=(prog --flag "$value"); "${cmd[@]}"`. Assembling a command in a single string re-introduces word-splitting and quoting bugs.
- **`"$@"`, not `$*`** — `"$@"` preserves each argument as a distinct word; a bare, unquoted `$*` joins on `$IFS` and then re-splits/globs the result, undoing the join. Use **`"$*"`** (quoted) only when joining into one word is deliberately intended — the unquoted form is never correct.

## Strict Mode & Error Handling

- Start every script: `#!/usr/bin/env bash` + `set -euo pipefail`. This is the baseline; a script without it (or an equivalent explicit error-handling strategy) is defective. **A sourced library is the exception** — it has no shebang and must not mutate the caller's `set` state; it inherits whatever the caller has set, and guards its own critical commands explicitly instead.
- **Know `set -e`'s blind spots** — it does NOT fire:
  - inside an `if`/`while` condition or the left side of `&&` / `||`,
  - in a **command substitution** unless `shopt -s inherit_errexit` is set,
  - in a **pipeline** for any command but the last, unless `pipefail` is on.
  Check critical commands explicitly (`cmd || die "…"`); never rely on `set -e` where it does not fire.
- **`cd … || exit`** (SC2164) — an unchecked `cd` that fails leaves the script acting in the wrong directory. Use `cd … || exit` / `cd … || return`.
- **`trap` cleanup on `EXIT`**; handle `INT` / `TERM` for graceful shutdown.
- **Exit codes carry meaning** (0 = ok, 2 = usage, …); write errors and diagnostics to **stderr**, never stdout.

## The Silent Traps

- **Exit-status masking (SC2155):** `local x=$(cmd)` / `readonly x=$(cmd)` **swallows the command's exit status** — `local`/`readonly` is itself a command that succeeds, so a failing `cmd` is hidden even under `set -e`. **Declare, then assign** when you need the status: `local x; x=$(cmd)`.
- **Subshell scope loss:** `cmd | while read -r …` runs the loop body in a **subshell**, so any variable set inside is **lost** after the loop. Use process substitution — `while IFS= read -r …; do …; done < <(cmd)` — or `shopt -s lastpipe`. The same loss applies to any `( … )` subshell.
- **Always `IFS= read -r`** (SC2162) — a bare `read` mangles backslashes and strips leading/trailing whitespace; `IFS= read -r` reads the line verbatim. For filenames (which can contain newlines), use null-delimited iteration (`find … -print0` / `read -r -d ''`), not line-based `read`.
- **`(( … ))` exit status:** an arithmetic expression that evaluates to `0` **returns exit status 1**, which trips `set -e`. Guard it (`(( x++ )) || true`) when the value can be zero.
- **Undefined variables:** without `set -u`, a typo silently expands to empty and corrupts behavior. Run under `set -u`; use `${var:?message}` for required values and `${var:-default}` for optional ones.

## Command Injection & Dynamic Execution

- Shell's own command-injection surface — `eval`, or `bash -c "$untrusted"` / `sh -c "$untrusted"` with an unquoted or attacker-influenced expansion — is arbitrary command execution; the general no-untrusted-input-to-eval/shell principle is `standard-security`'s (A05), not restated here.
- **`curl … | bash`** is the shell-specific instance of `standard-security`'s no-unpinned-external-script rule (A03) — not restated here; the shell adds no mechanism of its own beyond running the resulting payload with the caller's privileges.
- **Never let untrusted input reach an arithmetic context** — `(( … ))`, `[[ … -eq … ]]`, an array subscript, and a `declare -i` assignment all recursively evaluate their operand and can execute a command embedded in it (e.g. `n='x[0$(id)]'`). Validate as a strict integer before any of these touch it — this is why `[[ … ]]`'s numeric comparison is *not* automatically "safer" than `[ … ]` for an unvalidated value (see Comparisons & Arithmetic below).
- Untrusted-input validation before it reaches a command/path/sink is `standard-security`'s cross-cutting rule — not restated here; shell's own specific sinks are named throughout this section.

## Temp Files & TOCTOU

- **`mktemp` for temp files** — never predictable/fixed names (a predictable name is a symlink-attack and race surface). Pair it with a cleanup `trap` on `EXIT`.
- **Avoid TOCTOU races** — a check-then-use gap on a file or path (test existence/permissions, then act) can be won by an attacker between the two steps. Operate on the resource directly (open/create atomically) rather than checking then using.

## Secrets & Permissions

- **Arguments are visible to any user via `ps`** — the shell-specific reason `standard-security`'s no-secrets-on-command-line rule (A02) applies here, not restated here. Pass secrets via environment or a file with tight permissions (`600`).
- **Keep secrets out of `set -x` traces** specifically — the general never-log-secrets deny-list is `standard-observability`'s, not restated here; `set -x` is the shell-specific leak surface those diagnostics create.
- `chmod`/file-permission least privilege is `standard-security`'s own rule (A02) — not restated here; never `chmod 777` or leave a file/dir world-writable.

## Comparisons & Arithmetic

- **`[[ … ]]` over `[ … ]`** in Bash — safer (no word-splitting inside), supports `=~`/`&&`/`||`.
- **`(( … ))` for arithmetic** and numeric comparison; `[ … ]` mixes string and numeric comparison unsafely — `-eq` on a non-numeric value errors, and string-vs-numeric confusion causes off-by-one and wrong-branch bugs.

## Portability

- **Match the shebang to the features used** — if the script must be POSIX `sh`, avoid bashisms (arrays, `[[ ]]`, `local`, `${var,,}`, process substitution). If it uses bashisms, the shebang must be Bash.
- **GNU vs BSD divergence** on cross-platform scripts — `sed -i`, `date`, `stat`, `readlink`, `getopt`, `mktemp` (not POSIX; template/`-t` handling differs) take different flags/syntax on GNU (Linux) vs BSD (macOS). Branch on the platform or use portable forms (e.g. `mktemp "${TMPDIR:-/tmp}/name.XXXXXX"` with no template-format assumptions).
- **macOS ships Bash 3.2** at `/bin/bash` — no associative arrays, no `mapfile`/`readarray`, no `${var,,}`. Do not assume Bash 4+ there.
- **Bash < 4.4 (including macOS's 3.2) treats `"${arr[@]}"` on an *empty* array as unbound under `set -u`** and aborts — guard with `"${arr[@]+"${arr[@]}"}"` or check `${#arr[@]}` first before iterating a possibly-empty array under strict mode.

## Shellcheck

- **`shellcheck` clean is the bar.** Reference the **SC code** for every lint issue. High-signal codes: **SC2086** (quote expansions), **SC2046** (quote `$(…)`), **SC2155** (declare then assign), **SC2164** (`cd … || exit`), **SC2162** (`read -r`).
- **Justify every suppression** — an inline `# shellcheck disable=SCxxxx` must carry a reason; an unjustified disable is a defect.
