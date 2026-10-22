# Shell: development

Apply after `SKILL.md`'s rules, before writing any shell.

## Reporting

`standard-code-development-report` sets each item's shape.

- **The shebang** -> the report's `toolchain` (`#!/usr/bin/env sh` is POSIX `sh`, not Bash), because the reviewer checks every feature used against the shell it names.
- **Each Verification gate command and its result** -> the report's `verification`, one item per command, with each existing shellcheck warning in `note` with its count, and a step 4 you didn't run as `not_run` with its reason in `note`, never left out, because a gate result the report doesn't show reads as a gate that never ran.

## Defaults when the first message is silent

- **Always on:** strict mode, a quote on every expansion, and injection safety.
- **The target shell** comes from `SKILL.md`'s Target shell order.
- **The platforms** are all that `SKILL.md`'s Scope names.

## Edge cases

- **The first message names fewer platforms:** only the limits of the platforms it names apply; the Bash 3.2 limit stays while macOS's `/bin/bash` is one of them.
- **Needs root:** check `id -u` at the start, and stop with a message on stderr when it isn't 0.
- **Root only where needed:** run each step that doesn't need root as the invoking user, `sudo -u "$SUDO_USER" …`.
- **Changes system state:** offer a `--dry-run` that prints each change instead of making it.
- **Destructive step:** ask for confirmation before it runs.

## Verification gate

Run it on every shell file written or changed, before reporting done. Its tools are `shellcheck` and `bash` or `sh`.

`shellcheck` missing: macOS `brew install shellcheck`, Linux the distro's `shellcheck` package; record step 2 `not_run` with that hint as its note.

1. `head -1 <file>`: the shebang names the shell for step 3. A new file has the shebang `SKILL.md`'s Target shell settles.
2. `shellcheck -x -o all <file>`, with no new warnings: run it on the file before and after your change. `-o all` turns on the optional checks, such as `set -e`'s blind spots, which are off by default. The step passes when your change adds no warning.
3. `sh -n <file>` when the shebang names `sh`, `bash -n <file>` when it names Bash: the syntax check.
4. The script's own `--help`, or `--dry-run` where it has one, only when its code (not its usage text) shows that flag makes no write, delete, network call or change to system state; otherwise, or when you didn't check the code, don't run it.

## Self-check before reporting

1. The target shell was settled in `SKILL.md`'s order, and the shebang matches the features used.
2. Strict mode is set, or the file is a sourced library that sets nothing.
3. Every expansion that splits is quoted, and every built command is an array.
4. No untrusted value reaches `eval`, `sh -c` or arithmetic before validation.
5. Every temp file comes from `mktemp`, with an `EXIT` trap removing it.
6. Each gate step ran, step 2 only when shellcheck is installed, step 4 only where step 4 allows it.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
