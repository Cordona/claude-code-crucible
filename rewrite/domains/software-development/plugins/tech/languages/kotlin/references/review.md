# Kotlin: review

Apply with `SKILL.md`'s rules when judging Kotlin: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness for Kotlin:** this language plugin, with any framework plugins loaded beside it, judges whether the code does what it is meant to. Check for:
  - `!!` in production code, a platform-type NPE from Java interop, an unsafe `as`, a `lateinit` read before init;
  - a non-exhaustive `when` on a sealed type or enum, or an `else` that swallows a newly added variant;
  - an uncaught `launch` exception, a child `async` failure waved through as "handled at `await`", non-cooperative cancellation, a scope that outlives its lifecycle;
  - an `equals` or `hashCode` over an `Array` or mutable field, a `copy()` that defeats an invariant guarded only in a factory or private constructor, an Elvis or safe call that masks a real missing value;
  - integer overflow and off-by-one; an overflow with a security consequence is graded here, as correctness, not only arithmetic;
  - a missing `require` or `check` at a boundary;
  - boundary and error paths that are incomplete;
  - behaviour that breaks its intended contract.

## How to judge

- **Judge Java-interop code against `SKILL.md`'s platform-type rule first:** platform types escape the compiler's null checks, so the null checks there are held stricter.
- **DSL builder code may use receiver lambdas:** check each builder against `SKILL.md`'s `@DslMarker` rule.
- A secret written in the diff is a `found` item, as `code-reviewer` sets, never a finding of this lens.
- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.
- **Verify a library or `kotlinx.coroutines` API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a Kotlin defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:** none of its own; a HIGH defect reaches it only by What moves a level.
- **HIGH:**
  - a correctness defect from Correctness above;
  - a possible data race;
  - a secret value reachable outside its module, `internal` visibility being its only guard, against `SKILL.md`'s Secrets mechanism;
  - `!!`, a platform-type NPE or an unsafe `as`;
  - `GlobalScope`;
  - a blocking call on the wrong dispatcher;
  - non-cooperative cancellation.
- **MEDIUM:**
  - an unpinned dependency or another supply-chain gap, against `SKILL.md`'s Supply chain mechanism;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - `var` where `val` works;
  - micro-performance: boxing, needless copies;
  - a suppression with no written reason.

**Overrides:**
- **Test code:** a build diff that changes test code, a test module inside a source file included, is HIGH, as `code-reviewer` sets; no rule here grades test code lower.
- **Java-interop code:** hold it to the strictest null bar, an untrusted platform type with no null check included.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- `var` where `val` works rises above LOW when it is shared state.
- Micro-performance rises above LOW only on a hot path.
