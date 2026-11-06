# Shell script: development

## Edge cases

- **Needs root:** check `id -u` at the start, and stop with a message on stderr when it isn't 0.
- **Root only where needed:** run each step that doesn't need root as the invoking user, `sudo -u "$SUDO_USER" …`.
- **Changes system state:** offer a `--dry-run` that prints each change instead of making it.
- **Destructive step:** the script asks for confirmation before it runs.

## Verification gate

The full gate runs on every shell file written or changed. Its tools are `shellcheck`, `bash` or `sh`, and the project's test command.

No `shellcheck`, `bash` or `sh`: each step that needs it doesn't run, with what is missing and its install hint as the reason. The `shellcheck` hint: macOS `brew install shellcheck`, Linux the distro's `shellcheck` package.

Steps 1 and 2 set the baseline: each warning, error and finding, with its count; a new file's baseline is empty. After the change, every step runs, and steps 1 and 2 are compared against the baseline.

**Name each issue by its SC code** (`SC2086`): a finding with no id can't be matched against the baseline the gate compares to.

Before step 1, read the file's shebang (`head -1 <file>`): it names the shell for step 2, and a new file has the shebang the Toolchain order settles. It is not a gate step.

1. The lint check (gate `lint`): `shellcheck -x -o all <file>`. `-o all` turns on the optional checks, such as `set -e`'s blind spots, which are off by default.
2. The syntax check (gate `typecheck`): `sh -n <file>` when the shebang names `sh`, `bash -n <file>` when it names Bash.
3. The existing tests (gate `test`): the project's own test command, where one exists, such as a `test` target or a `bats` suite its docs name. None: it doesn't run, for the reason "no test command".
4. The guarded run (gate `manual`): the script's own `--help`, or `--dry-run` where it has one, only when its code (not its usage text) shows that flag makes no write, delete, network call or change to system state; otherwise, or when you didn't check the code, don't run it.

Shell has no build step.

## Self-check before reporting

1. The target shell was settled in the Toolchain order, and the shebang matches the features used.
2. Strict mode is set, or the file is a sourced library that sets nothing.
3. Every expansion that splits is quoted, and every built command is an array.
4. No untrusted value reaches `eval`, `sh -c` or arithmetic before validation.
5. Every temp file comes from `mktemp`, with an `EXIT` trap removing it.
