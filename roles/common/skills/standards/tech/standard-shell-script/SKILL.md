---
name: standard-shell-script
description: The single definition of idiomatic, correct, safe shell — the shared language rubric that the shell-script-developer BUILDS to and the shell-script-reviewer REVIEWS against. Applies whenever Bash / POSIX shell is written, changed, or reviewed (deployment automation, CI/CD steps, cron jobs, CLI tools, container entrypoints, sysadmin scripts). Defines strict mode and set -e's blind spots, defensive quoting and word-splitting (SC2086), building commands as arrays, the exit-status-masking and subshell-scope-loss traps (SC2155, cmd | while read), eval/command-injection safety, temp-file/TOCTOU hygiene (mktemp + trap), secrets and permissions, [[ ]] / (( )) comparison idioms, portability (bashisms, GNU vs BSD, macOS Bash 3.2), and shellcheck SC-code discipline. This is WHAT good shell looks like; it does not define builder workflow (build-core), the reviewer's correctness-detective method / scope-boundary / severity / category vocabulary / SC-code scoring (the shell-script-reviewer), or the build/report envelopes (build-report-standards / review-report-standards).
---

# Standard: Shell Script

The **one** definition of what good, correct, safe shell looks like. The `shell-script-developer` builds to it; the `shell-script-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we write shell and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like** — the idioms to reach for and the traps to avoid. It is **NOT a shell tutorial**: assume fluent Bash/POSIX, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: the builder's workflow and validation gate (`build-core` / the developer), or the reviewer's machinery — the correctness-detective method, scope-boundary/handoff, severity, `category` vocabulary, and SC-code scoring live with the `shell-script-reviewer`; report envelopes live in `build-report-standards` / `review-report-standards`.

Assume **Bash 4+** (`#!/usr/bin/env bash`) unless POSIX `sh` is required. But **macOS ships Bash 3.2** at `/bin/bash` — no associative arrays, no `mapfile`/`readarray`, no `${var,,}` case-conversion — so do not assume Bash 4+ features on scripts that must run there.

## Strict Mode & Error Handling

- Start every script: `#!/usr/bin/env bash` + `set -euo pipefail`. This is the baseline; a script without it (or an equivalent explicit error-handling strategy) is defective.
- **Know `set -e`'s blind spots** — it does NOT fire:
  - inside an `if`/`while` condition or the left side of `&&` / `||`,
  - in a **command substitution** unless `shopt -s inherit_errexit` is set,
  - in a **pipeline** for any command but the last, unless `pipefail` is on.
  Check critical commands explicitly (`cmd || die "…"`); never rely on `set -e` where it does not fire.
- **`cd … || exit`** (SC2164) — an unchecked `cd` that fails leaves the script acting in the wrong directory. Use `cd … || exit` / `cd … || return`.
- **`trap` cleanup on `EXIT`**; handle `INT` / `TERM` for graceful shutdown.
- **Exit codes carry meaning** (0 = ok, 2 = usage, …); write errors and diagnostics to **stderr**, never stdout.

## Quoting & Expansion (the #1 correctness & safety surface)

- **Quote every expansion**: `"$var"`, `"${array[@]}"`, `"$(cmd)"`. An unquoted expansion undergoes **word-splitting + glob expansion**, which changes behavior and opens an injection/word-splitting surface (SC2086; SC2046 on unquoted `$(…)`; SC2068 on unquoted `${arr[@]}`).
- **Build commands as arrays, never as strings** — `cmd=(prog --flag "$value"); "${cmd[@]}"`. Assembling a command in a single string re-introduces word-splitting and quoting bugs.
- **`"$@"`, not `$*`** — `"$@"` preserves each argument as a distinct word; `$*` joins and re-splits them. Use `$*` only when that joining is deliberately intended.

## The Silent Traps

- **Exit-status masking (SC2155):** `local x=$(cmd)` / `readonly x=$(cmd)` **swallows the command's exit status** — `local`/`readonly` is itself a command that succeeds, so a failing `cmd` is hidden even under `set -e`. **Declare, then assign** when you need the status: `local x; x=$(cmd)`.
- **Subshell scope loss:** `cmd | while read -r …` runs the loop body in a **subshell**, so any variable set inside is **lost** after the loop. Use process substitution — `while read -r …; do …; done < <(cmd)` — or `shopt -s lastpipe`. The same loss applies to any `( … )` subshell.
- **Always `read -r`** (SC2162) — a bare `read` mangles backslashes; `read -r` reads the line verbatim.
- **`(( … ))` exit status:** an arithmetic expression that evaluates to `0` **returns exit status 1**, which trips `set -e`. Guard it (`(( x++ )) || true`) when the value can be zero.
- **Undefined variables:** without `set -u`, a typo silently expands to empty and corrupts behavior. Run under `set -u`; use `${var:?message}` for required values and `${var:-default}` for optional ones.

## Command Injection & Dynamic Execution

- **Never `eval` untrusted input**, and never `bash -c "$untrusted"` / `sh -c "$untrusted"` with an unquoted or attacker-influenced expansion — this is arbitrary command execution.
- **Never pipe an untrusted source into a shell** (`curl … | bash`) — an unverified remote payload runs with the caller's privileges.
- Validate / allow-list untrusted input before it reaches any command, path, or sink.

## Temp Files & TOCTOU

- **`mktemp` for temp files** — never predictable/fixed names (a predictable name is a symlink-attack and race surface). Pair it with a cleanup `trap` on `EXIT`.
- **Avoid TOCTOU races** — a check-then-use gap on a file or path (test existence/permissions, then act) can be won by an attacker between the two steps. Operate on the resource directly (open/create atomically) rather than checking then using.

## Secrets & Permissions

- **Keep secrets out of argv** — arguments are visible to any user via `ps`. Pass secrets via environment or a file with tight permissions (`600`).
- **Never log secrets** — keep them out of `set -x` traces, error messages, and diagnostics.
- **`chmod` tightly** — least privilege; never `chmod 777` or world-writable files/dirs.

## Comparisons & Arithmetic

- **`[[ … ]]` over `[ … ]`** in Bash — safer (no word-splitting inside), supports `=~`/`&&`/`||`.
- **`(( … ))` for arithmetic** and numeric comparison; `[ … ]` mixes string and numeric comparison unsafely — `-eq` on a non-numeric value errors, and string-vs-numeric confusion causes off-by-one and wrong-branch bugs.

## Portability

- **Match the shebang to the features used** — if the script must be POSIX `sh`, avoid bashisms (arrays, `[[ ]]`, `local`, `${var,,}`, process substitution). If it uses bashisms, the shebang must be Bash.
- **GNU vs BSD divergence** on cross-platform scripts — `sed -i`, `date`, `stat`, `readlink`, `getopt` take different flags/syntax on GNU (Linux) vs BSD (macOS). Branch on the platform or use portable forms.
- **macOS ships Bash 3.2** at `/bin/bash` — no associative arrays, no `mapfile`/`readarray`, no `${var,,}`. Do not assume Bash 4+ there.

## Shellcheck

- **`shellcheck` clean is the bar.** Reference the **SC code** for every lint issue. High-signal codes: **SC2086** (quote expansions), **SC2046** (quote `$(…)`), **SC2155** (declare then assign), **SC2164** (`cd … || exit`), **SC2162** (`read -r`).
- **Justify every suppression** — an inline `# shellcheck disable=SCxxxx` must carry a reason; an unjustified disable is a defect.

---
*Standard Version: 1.0 — the shared shell rubric. Built to by the shell-script-developer (via build-core); reviewed against by the shell-script-reviewer.*
