---
name: standard-php
description: The single rubric for idiomatic, correct PHP — what the php-developer BUILDS to and the php-reviewer REVIEWS against. Applies whenever PHP code is written, changed, or reviewed (plain, Laravel, Symfony, Doctrine, Eloquent). Covers strict typing/modern idioms, type-juggling and float-comparison traps, null/array-access safety, boundary decoding, exhaustiveness, arithmetic, exception discipline, ORM/framework correctness, PHP micro-performance, and static-analysis cleanliness. Does NOT define builder workflow (build-core), the reviewer's own correctness-detective framing, category vocabulary, and scope-boundary table (genuinely php-reviewer's own), the base severity scale/handoff mechanism (review-core / review-report-standards), the build/report envelopes (build-report-standards / review-report-standards), generic security (standard-security), or generic clean-code/self-documenting-code/performance/observability/persistence (their own standards).
---

# Standard: PHP

The **one** definition of what good, correct PHP looks like. The `php-developer` builds to it; the `php-reviewer` judges against it. Both bind this single skill, so there is no daylight between how PHP is built and how it is reviewed — a rule changed here moves both sides at once.

This skill assumes **fluent PHP** and encodes only the non-default priorities and easy-to-miss pitfalls — it is **NOT a PHP tutorial**. Assume **PHP 8.4** unless told otherwise; map every framework example (Laravel/Symfony, Eloquent/Doctrine) to the target project's actual stack.

This skill defines **WHAT good looks like**. It does NOT contain: the builder's workflow (`build-core`); the reviewer's correctness-detective framing, `category` vocabulary, and scope-boundary table (genuinely `php-reviewer`'s own); the base severity scale and handoff mechanism (`review-core` / `review-report-standards` — `php-reviewer` only maps its own categories onto that scale); the build/report envelopes (`build-report-standards` / `review-report-standards`); generic **security** (injection, XSS, secrets, authz, mass-assignment as a security control → `standard-security`); or generic **clean-code / self-documenting-code / performance / observability / persistence** (their own standards). Here: the language itself — its type system, its traps, and framework *correctness*.

## Strict typing & modern PHP

- **`declare(strict_types=1)` in every new file** — non-negotiable; without it PHP coerces argument/return types silently.
- **Type everything** — properties, params, and returns, using union/intersection types, `enum`, and `readonly`. Type returns honestly (`?T`, `never`). Avoid `mixed` where a real type fits.
- **Constructor property promotion**; `readonly` for value objects; **enums** for fixed sets; `#[\Override]` on overrides; `?->` and `??` for null flows.

## Type juggling & comparisons

- **Prefer `===`/`!==`; never loose `==`/`!=`.** Loose comparison type-juggles: `0 == "abc"`, `"1e3" == "1000"`, `"" == null` all surprise. Logic- or security-sensitive comparisons with `==` are bugs.
- **Strict mode for the comparison built-ins** — `in_array($needle, $haystack, true)`, `array_search(…, true)`, and `switch` all compare **loosely by default**; pass strict / avoid `switch` where the loose match is wrong.
- **Float comparison is unsafe with `==` *and* `===`.** Floating-point representation makes `0.1 + 0.2 === 0.3` evaluate to `false` — `===` does NOT rescue it. Compare floats with an **epsilon** (`abs($a - $b) < $epsilon`) or `bccomp`/arbitrary-precision math, never `==` or `===`.

## Null & array-access safety

- **An undefined array key or property is a bug, not a default.** Guard access with `isset`/`array_key_exists`/`??`; do not read a key you have not proven present.
- **`?->` can mask a real null** — a null-safe chain that silently short-circuits where the value was *required* hides the defect instead of surfacing it.
- **`??` can hide a missing *required* value** — supplying a default for something that must be present converts a loud failure into silent wrong behavior.

## Boundary decoding

- **Decode strictly at boundaries.** Bare `json_decode($s)` returns `null` for **both** invalid JSON *and* a literal `null` — indistinguishable. Use `json_decode($s, flags: JSON_THROW_ON_ERROR)` (or `json_validate()` on 8.3) so malformed input throws instead of yielding a silent `null`.
- **Backed enums:** `Enum::from($value)` throws `\ValueError` on an unknown value. For untrusted or DB-sourced input use **`tryFrom()`** (returns `null` to handle) — reserve `from()` for values already known-valid.

## Exhaustiveness

- **Prefer `match` over `switch`.** `switch` falls through on a missing `break`; `match` compares strictly and throws **`UnhandledMatchError`** on an unhandled arm — turning a silent gap into a loud failure.
- **Handle enums exhaustively.** A `match` over an enum with no `default` fails loudly when a new case is added; a `switch` (or a `default` that swallows) hides the gap.

## Arithmetic

- **Integer overflow silently promotes to `float`** — PHP does not wrap or error; `PHP_INT_MAX + 1` becomes a float, losing integer precision. Guard size/index/financial math where this matters.
- Watch off-by-one at boundaries. (An overflow with a *security* consequence — fraud, over-allocation, OOB index — is a security concern; the arithmetic-correctness aspect is PHP's.)

## Exception discipline

- **No empty `catch`** and **no over-broad `catch (\Throwable)`** that swallows unrelated failures — catch the specific exception you can handle.
- **Do not swallow errors** — a caught exception must be handled, rethrown, or logged; never silently discarded.
- **Exceptions are not control flow** — do not use them for ordinary branching.
- Throw **domain exceptions** from the right base type.

## Framework correctness (Eloquent / Doctrine — illustrative)

- **Relationship loading** — eager-load relations that are used (the *correctness* twin of the N+1 *performance* problem); never access a lazy relation after the entity manager / connection is closed (`LazyInitialization`-style bugs).
- **Transaction boundaries** — `DB::transaction()`'s closure semantics (auto-commit/rollback) vs. Doctrine's explicit `beginTransaction`/`commit` and its savepoint requirement for genuine nesting; the store-agnostic atomicity rule itself is `standard-persistence`'s.
- **Persistence & identity map** — flush/persist dirty state before it is expected to be durable; account for identity-map behavior (the same row returns the same instance) rather than being surprised by it.

## PHP micro-performance (language-level)

Language-level allocation/execution hygiene, distinct from algorithmic complexity (`standard-performance`'s job):

- Avoid recompiling the same regex/pattern inside a loop — hoist `preg_*`'s pattern compilation out, or use a cached/prepared form.
- Prefer array functions (`array_map`/`array_filter`/`array_reduce`) or a plain loop over per-element object/closure overhead on a hot path.
- OPcache should be enabled in production; a change that defeats it (e.g. `eval()`, dynamic `include` paths) is a defect on a hot path.

## Static-analysis cleanliness

- Code passes PHPStan or Psalm at the project's configured level with zero errors; an unjustified `@phpstan-ignore-line` / `@psalm-suppress` is a defect the same way an unjustified suppression is in any other language this repo builds.
- **PSR-12** (PHP-FIG's Extended Coding Style Guide) is the style baseline; style/formatting conformance is a linter's job (`php-cs-fixer`/`phpcs`), not a manual review job.
