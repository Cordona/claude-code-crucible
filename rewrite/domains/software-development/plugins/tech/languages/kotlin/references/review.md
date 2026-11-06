# Kotlin: review

## Correctness

- **Check for these Kotlin correctness defects:**
  - `!!` in production code, a platform-type NPE from Java interop, an unsafe `as`, a `lateinit` read before init;
  - a non-exhaustive `when` on a sealed type or enum, or an `else` that swallows a newly added variant;
  - an uncaught `launch` exception, a child `async` failure waved through as "handled at `await`", non-cooperative cancellation, a scope that outlives its lifecycle;
  - an `equals` or `hashCode` over an `Array` or mutable field, a `copy()` that defeats an invariant guarded only in a factory or private constructor, an Elvis or safe call that masks a real missing value;
  - integer overflow and off-by-one, including an overflow with a security consequence;
  - a missing `require` or `check` at a boundary.

## How to judge

- **Judge Java-interop code against the platform-type rule first:** platform types escape the compiler's null checks, so the null checks there are held stricter.
- **DSL builder code may use receiver lambdas:** check each builder against the `@DslMarker` rule.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.

## Severity

- **HIGH:**
  - a possible data race;
  - a secret value reachable outside its module, `internal` visibility being its only guard, against the Secrets mechanism;
  - `GlobalScope`;
  - a blocking call on the wrong dispatcher.
- **MEDIUM:**
  - an unpinned dependency or another supply-chain gap, against the Supply chain mechanism;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - `var` where `val` works;
  - micro-performance: boxing, needless copies;
  - a suppression with no written reason.

**What moves a level:**
- `var` where `val` works rises above LOW when it is shared state.
- Micro-performance rises above LOW only on a hot path.
