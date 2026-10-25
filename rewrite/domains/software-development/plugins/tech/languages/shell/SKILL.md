---
name: language-shell
description: Shell (Bash and POSIX `sh`) rules for writing scripts — the target shell, quoting, strict mode, silent traps, injection, temp files, leak surfaces, portability and shellcheck, plus the developer's verification gate. A language plugin, injected into the agent's first message when loaded. Writes nothing; the gate needs `shellcheck`. Not for shell embedded in another file (a Dockerfile `RUN`, a CI step), or for rules every language shares (`code-developer` and the standard plugins).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Shell script
---

# Language: Shell script

The rules that are specific to shell scripts, in Bash or POSIX `sh`. Every role receives this file in its prompt. A developer then receives `references/development.md` right after it: what to report, the defaults, the edge cases and the verification gate. A reviewer receives `references/review.md` right after it instead: how to judge a finding and how to grade it.

## Scope

- **In:** standalone scripts and sourced libraries run by `bash` or `sh`. Each runs on Linux, macOS, and Windows under Git Bash and WSL, unless the first message names fewer platforms.
- **Out:** shell embedded in another file, such as a Dockerfile `RUN` line or a CI step, and native Windows `cmd` and PowerShell.

## Target shell

Settle it before writing a line. The first match wins:

1. The file's own shebang.
2. For a new file, the shebang of its sibling scripts. Siblings on `#!/usr/bin/env sh` mean POSIX `sh`.
3. What the project's own docs on its shell code say, where the task's context lists them.
4. Otherwise Bash, with `#!/usr/bin/env bash`. Whichever shell wins, the script runs on every platform Scope names.

## Quoting, expansion and comparisons

- **Quote every expansion:** `"$var"`, `"${arr[@]}"`, `"$(cmd)"`. Unquoted, the value is split on `IFS` and globbed (SC2086, SC2046, SC2068).
- **Splitting doesn't happen** on an assignment's right side, inside `[[ ]]`, in a `case` word or in `(( ))`. A missing quote there is no defect.
- **Build a command as an array,** `cmd=(prog --flag "$v")` then `"${cmd[@]}"`, never as a string: a string re-splits.
- **Pass arguments on with `"$@"`.** A bare `$*` re-splits and globs; use `"$*"` only to join into one word on purpose.
- **In Bash, test with `[[ ]]`, not `[ ]`:** nothing splits inside it, and `=~`, `&&` and `||` work.
- **Compare numbers with `(( ))`.** `[ ]` mixes string and number tests, and `-eq` on a non-number errors.

## Strict mode and errors

- **Bash scripts start with `set -euo pipefail`.** POSIX `sh` scripts use `set -eu`, adding `set -o pipefail` only where the target `sh` supports it.
- **A sourced library has no shebang and sets nothing:** it inherits the caller's `set` state, and checks its own critical commands.
- **`set -e` stays silent** in an `if` or `while` condition, on the left of `&&` or `||`, in a command substitution (`shopt -s inherit_errexit` changes that only from Bash 4.4), and in a pipeline before its last command (unless `pipefail`). Check a critical command there yourself: `cmd || die "…"`.
- **`cd "$dir" || exit`** (SC2164): after a failed `cd`, the rest runs in the wrong directory.
- **Clean up in a `trap` on `EXIT`:** it runs on every way out, a failure included.
- **Trap `INT` and `TERM` as well,** for a graceful stop.
- **Errors and diagnostics go to stderr, never stdout:** a caller capturing stdout parses them as data.
- **Exit 0 on success and 2 on a usage error:** a caller branches on the code, not the text.

## The silent traps

- **`local x=$(cmd)` hides `cmd`'s failure,** even under `set -e` (SC2155); so does `readonly`. Declare, then assign: `local x; x=$(cmd)`.
- **`cmd | while read …` runs the loop in a subshell,** so variables set in it are lost after it. Use `done < <(cmd)`; `shopt -s lastpipe` needs Bash 4.2, past the 3.2 limit.
- **Read lines with `IFS= read -r`** (SC2162): a bare `read` eats backslashes and edge whitespace.
- **Filenames can hold newlines:** iterate them null-delimited, `find … -print0` with `read -r -d ''`.
- **`(( expr ))` that comes to 0 returns status 1** and trips `set -e`. Write `(( x++ )) || true` where the value can be 0.
- **Forking a process per input line is slow:** a `while read` loop that calls `sed`, `grep` or `awk` on each line starts one process per line. Use one `awk`, `sed` or `grep` over the whole input.
- **Under `set -u`,** take a required value with `${var:?message}` and an optional one with `${var:-default}`.

## Injection

- **`eval`, `bash -c "$x"` and `sh -c "$x"` run whatever `$x` holds:** never hand them untrusted input.
- **Arithmetic runs commands hidden in its operand:** `(( ))`, `[[ $a -eq $b ]]`, an array subscript and `declare -i` all do. With `n='x[0$(id)]'`, `(( n ))` runs `id`.
- **Validate untrusted input as a strict integer** before any arithmetic sees it: `[[ $n =~ ^[0-9]+$ ]]` in Bash, `case $n in ''|*[!0-9]*) die …;; esac` in `sh`.

## Temp files and leak surfaces

- **Create temp files with `mktemp`** and remove them in the `EXIT` trap. A fixed or guessable name invites symlink and race attacks.
- **Act on the file directly** (create it, open it) instead of checking first and acting after: the gap between the two is a TOCTOU race.
- **Hand a fetched secret to one child as `VAR="$secret" cmd`,** not on its argv, which `ps` shows, and not `export`ed, which every later child inherits.
- **`set -x` prints each command with its values expanded,** secrets included: keep tracing off around them.
- **Write a secret file under `umask 077`,** set in a subshell so the mask goes no further, never `chmod 600` after the write: the file is readable in between.

## Portability

- **The shebang matches the features used:** under `sh`, no arrays, `[[ ]]`, `local`, `${v,,}` or process substitution.
- **macOS `/bin/bash` is 3.2** (see Version ledger), so Bash scripts use Bash 3.2 features only: no associative arrays, `mapfile` or `readarray`, `${v,,}` or `${v^^}`, `globstar` or `declare -n`.
- **An empty `"${arr[@]}"` aborts under `set -u` before Bash 4.4,** 3.2 included. Guard it with `${arr[@]+"${arr[@]}"}`; test `${#arr[@]}` first only when the empty case needs its own branch.
- **GNU and BSD tools differ** on `sed -i`, `date`, `stat`, `readlink`, `getopt` and `mktemp`; Git Bash and the default WSL distro carry the GNU forms (an Alpine WSL distro has BusyBox). Use a form every platform accepts; branch on `uname -s` (`Linux`, `Darwin`, or `MINGW*` and `MSYS*` under Git Bash) only where no such form exists.

## Windows: Git Bash and WSL

- **Keep LF line endings:** a CRLF script fails with `$'\r': command not found`, or a shebang naming `bash\r`. `*.sh text eol=lf` in `.gitattributes` stops Git converting them.
- **Paths take two forms:** `C:\Users` is `/c/Users` in Git Bash and `/mnt/c/Users` in WSL; a native Windows program wants `C:\Users`. Convert with `cygpath -w` (Git Bash) or `wslpath -w` (WSL).
- **Quote every path:** Windows paths often hold spaces.
- **Git Bash rewrites an argument that looks like a POSIX path** passed to a native Windows program; set `MSYS_NO_PATHCONV=1` on a call that must keep it as written.
- **Don't rely on `chmod` or `ln -s`:** under Git Bash, `chmod +x` often does nothing and `ln -s` may copy the file. Where the mode can't be trusted, run the script as `bash <file>`.
- **Never ship two file names that differ only in case:** Windows, and macOS by default, are case-insensitive.
- **Write each path in its exact case:** the wrong case works on Windows and macOS and breaks on Linux.
- **A tool can be missing or differ under Git Bash** (no `rsync`; `ping` is Windows' own, counting with `-n`): check it with `command -v` and stop with a message naming it; branch on `uname -s` only where a Git Bash stand-in exists.

## Shellcheck

- **Shellcheck-clean is the bar.**
- **Name each issue by its SC code.**
- **Every `# shellcheck disable=SCnnnn` carries its reason:** an unexplained disable is a defect.

## Version ledger

| Fact | Value | Last verified |
|---|---|---|
| macOS `/bin/bash` | 3.2.57 | 2026-10-14, macOS 26.5.2 |
