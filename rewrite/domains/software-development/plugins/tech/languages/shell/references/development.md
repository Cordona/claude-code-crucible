# Shell script: development

Apply after `SKILL.md`'s rules, before writing any shell.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The toolchain found** (the shebang; `#!/usr/bin/env sh` is POSIX `sh`, not Bash) -> the report's `toolchain`, because the reviewer judges the code against the shell it names.
- **Each Verification gate command and its result** -> the report's `verification`, one item per command, its `gate` value as its step names it, because a gate result the report doesn't show reads as a gate that never ran.
- **Each warning, error or finding that predates your change** goes in its command's `note`, with its count.
- **A step you didn't run** is `not_run`, with its reason in `note`, or `narrowed` when `TASK` narrowed it; never leave it out.

## Defaults when the first message is silent

- **Always on:** strict mode, a quote on every expansion, and injection safety.
- **The target shell** comes from `SKILL.md`'s Toolchain order.
- **The platforms** are all that `SKILL.md`'s Scope names.

## Edge cases

- **The first message names fewer platforms:** only the limits of the platforms it names apply; the Bash 3.2 limit stays while macOS's `/bin/bash` is one of them.
- **Needs root:** check `id -u` at the start, and stop with a message on stderr when it isn't 0.
- **Root only where needed:** run each step that doesn't need root as the invoking user, `sudo -u "$SUDO_USER" …`.
- **Changes system state:** offer a `--dry-run` that prints each change instead of making it.
- **Destructive step:** ask for confirmation before it runs.

## Verification gate

Take the baseline before your first edit; run the full gate on every change, before reporting done, on every shell file written or changed. Its tools are `shellcheck`, `bash` or `sh`, and the project's test command.

The gate writes only what the project's own tests write.

The gate fetches and installs nothing: never install `shellcheck` or a shell. No `shellcheck`, `bash` or `sh`: record each step that needs it `not_run`, with a note naming what is missing and its install hint: a hint to record, never a command to run. The `shellcheck` hint: macOS `brew install shellcheck`, Linux the distro's `shellcheck` package.

Before your first edit, run steps 1 and 2 and record each warning, error and finding with its count as the baseline; a new file's baseline is empty. After the change, run every step and compare steps 1 and 2 against the baseline.

Before step 1, read the file's shebang (`head -1 <file>`): it names the shell for step 2, and a new file has the shebang `SKILL.md`'s Toolchain settles. It is no gate item.

1. The lint check (gate `lint`): `shellcheck -x -o all <file>`. `-o all` turns on the optional checks, such as `set -e`'s blind spots, which are off by default. It passes when your change adds nothing to the baseline.
2. The syntax check (gate `typecheck`): `sh -n <file>` when the shebang names `sh`, `bash -n <file>` when it names Bash. It passes when your change adds nothing to the baseline.
3. The existing tests (gate `test`): the project's own test command, where one exists, such as a `test` target or a `bats` suite its docs name. None: `not_run`, with "no test command" as its note.
4. The guarded run (gate `manual`): the script's own `--help`, or `--dry-run` where it has one, only when its code (not its usage text) shows that flag makes no write, delete, network call or change to system state; otherwise, or when you didn't check the code, don't run it.

Shell has no build step.

## Self-check before reporting

1. The target shell was settled in `SKILL.md`'s order, and the shebang matches the features used.
2. Strict mode is set, or the file is a sourced library that sets nothing.
3. Every expansion that splits is quoted, and every built command is an array.
4. No untrusted value reaches `eval`, `sh -c` or arithmetic before validation.
5. Every temp file comes from `mktemp`, with an `EXIT` trap removing it.
6. Each gate step ran, or is `not_run` or `narrowed` with its reason.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
