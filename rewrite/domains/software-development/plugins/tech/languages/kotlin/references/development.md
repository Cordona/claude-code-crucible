# Kotlin: development

## Defaults when nothing given says otherwise

- **A new dependency goes into the build file only;** its download is left to the human: record it, and a gate step that needs it doesn't run.
- **A new build uses the Gradle Kotlin DSL** (`build.gradle.kts`).

## Verification gate

The gate runs through the project's wrapper: `./gradlew`, or `./mvnw` for Maven. Its tools are the wrapper, or an installed `gradle` or `mvn`, and a JDK; `ktlint` and `detekt` only where the project configures them.

Run the wrapper with `--offline` (`-o` for Maven), and only when its distribution is already downloaded. No wrapper and no installed `gradle` or `mvn`, or no JDK: each step that needs it doesn't run, with what is missing and its install hint as the reason.

The baseline is steps 1, 2 and 3: each warning, error and finding with its count; a new file's baseline is empty. After the change, run every step and compare steps 1, 2 and 3 against the baseline.

**Name each finding by its rule id:** a finding with no id can't be matched against the baseline the gate compares to.

1. The format check (gate `format`), only where the project configures a formatter: `./gradlew --offline ktlintCheck`, or its equivalent. Not configured: it doesn't run, for the reason "not configured".
2. The compile check (gate `typecheck`), main and test sources: `./gradlew --offline compileKotlin compileTestKotlin`, or `./mvnw -o test-compile`.
3. The lint check (gate `lint`), only where the project configures `detekt` or `ktlint`: `./gradlew --offline detekt`, or the project's equivalent task. Not configured: it doesn't run, for the reason "not configured".
4. The existing tests (gate `test`): `./gradlew --offline test`, or `./mvnw -o test`.

A build (`./gradlew build`) is not a per-change gate.

## Self-check before reporting

1. The toolchain was settled in the Toolchain order.
2. No `!!` in production code, and each Java platform type is checked at the boundary.
3. No `GlobalScope`, no `runBlocking` on a production path, and no blocking call on `Dispatchers.Default`.
4. Each data class invariant sits in `init {}`, so `copy()` re-checks it.
