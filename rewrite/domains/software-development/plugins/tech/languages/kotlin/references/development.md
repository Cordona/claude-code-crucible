# Kotlin: development

Apply after `SKILL.md`'s rules, before writing any Kotlin.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The toolchain found** (Kotlin version, JVM target, build tool and its version) -> the report's `toolchain`, because the reviewer judges the code against the Kotlin version and JVM target it names.
- **Each Verification gate command and its result** -> the report's `verification`, one item per command, its `gate` value as its step names it, because a gate result the report doesn't show reads as a gate that never ran.
- **Each warning, error or finding that predates your change** goes in its command's `note`, with its count.
- **A step you didn't run** is `not_run`, with its reason in `note`, or `narrowed` when `TASK` narrowed it; never leave it out.

## Defaults when the first message is silent

- **The toolchain** comes from `SKILL.md`'s Toolchain order.
- **A new build uses the Gradle Kotlin DSL** (`build.gradle.kts`).

## Edge cases

- **Java interop is needed:** follow `SKILL.md`'s Java interop rule, and its Null safety rule on platform types.

## Verification gate

Take the baseline before your first edit; run the full gate on every change, before reporting done, through the project's wrapper: `./gradlew`, or `./mvnw` for Maven. Its tools are the wrapper, or an installed `gradle` or `mvn`, and a JDK; `ktlint` and `detekt` only where the project configures them.

The gate writes only the build tool's output (`build/` or `target/`) and its caches.

The gate fetches and installs nothing: run the wrapper with `--offline` (`-o` for Maven), and only when its distribution is already downloaded. A step that would need a download is `not_run`, as for a missing tool. No wrapper and no installed `gradle` or `mvn`, or no JDK: record each step that needs it `not_run`, with a note naming what is missing and its install hint: a hint to record, never a command to run.

Before your first edit, run steps 1, 2 and 3 and record each warning, error and finding with its count as the baseline; a new file's baseline is empty. After the change, run every step and compare steps 1, 2 and 3 against the baseline.

1. The format check (gate `format`), only where the project configures a formatter: `./gradlew --offline ktlintCheck`, or its equivalent. It passes when your change adds nothing to the baseline. Not configured: `not_run`, with "not configured" as its note.
2. The compile check (gate `typecheck`), main and test sources: `./gradlew --offline compileKotlin compileTestKotlin`, or `./mvnw -o test-compile`. It passes when your change adds nothing to the baseline.
3. The lint check (gate `lint`), only where the project configures `detekt` or `ktlint`: `./gradlew --offline detekt`, or the project's equivalent task. It passes when your change adds nothing to the baseline. Not configured: `not_run`, with "not configured" as its note.
4. The existing tests (gate `test`): `./gradlew --offline test`, or `./mvnw -o test`.

A build (`./gradlew build`) is not a per-change gate.

## Self-check before reporting

1. The toolchain was settled in `SKILL.md`'s order.
2. No `!!` in production code, and each Java platform type is checked at the boundary.
3. No `GlobalScope`, no `runBlocking` on a production path, and no blocking call on `Dispatchers.Default`.
4. Each data class invariant sits in `init {}`, so `copy()` re-checks it.
5. Each gate step ran, or is `not_run` or `narrowed` with its reason.
6. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
