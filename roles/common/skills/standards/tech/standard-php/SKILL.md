---
name: standard-php
description: The single definition of idiomatic, correct PHP — the shared rubric that the php-developer BUILDS to and the php-reviewer REVIEWS against. Applies whenever PHP code is written, changed, or reviewed (Laravel, Symfony, Doctrine, Eloquent, or plain PHP). Defines strict typing and modern PHP idioms (declare(strict_types=1), typed properties/params/returns, constructor promotion, readonly, enums, match), the type-juggling traps (loose ==/!= pitfalls, non-strict in_array/array_search/switch), unsafe float comparison (== AND === both fail on floats), boundary decoding (json_decode with JSON_THROW_ON_ERROR, enum from()/tryFrom()), null & array-access safety, exhaustiveness (switch fall-through vs match/UnhandledMatchError), arithmetic (int overflow promotes to float), exception discipline, and framework correctness (ORM loading, transaction boundaries, identity map). This is WHAT good PHP looks like; it does not define builder workflow (build-core), the reviewer's correctness-detective framing / severity / category vocabulary / handoff (the php-reviewer), generic security (standard-security), or generic clean-code, performance, testing, and observability (their own standards).
---

# Standard: PHP

The **one** definition of what good, correct PHP looks like. The `php-developer` builds to it; the `php-reviewer` judges against it. Both bind this single skill, so there is no daylight between how PHP is built and how it is reviewed — a rule changed here moves both sides at once.

This skill assumes **fluent PHP** and encodes only the non-default priorities and easy-to-miss pitfalls — it is **NOT a PHP tutorial**. Assume **PHP 8.3** unless told otherwise; map every framework example (Laravel/Symfony, Eloquent/Doctrine) to the target project's actual stack.

This skill defines **WHAT good looks like**. It does NOT contain: the builder's workflow (`build-core`); the reviewer's machinery (correctness-detective framing, severity, `category` vocabulary, scope-boundary/handoff — those live in the `php-reviewer`); generic **security** (injection, XSS, secrets, authz, mass-assignment as a security control → `standard-security`); or generic **clean-code / performance / testing / observability** (their own standards). Here: the language itself — its type system, its traps, and framework *correctness*.

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

- **Prefer `match` over `switch`.** `switch` compares loosely and falls through on a missing `break`; `match` compares strictly and throws **`UnhandledMatchError`** on an unhandled arm — turning a silent gap into a loud failure.
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
- **Transaction boundaries** — wrap multi-write operations in a single transaction; do not rely on incorrect nesting assumptions.
- **Persistence & identity map** — flush/persist dirty state before it is expected to be durable; account for identity-map behavior (the same row returns the same instance) rather than being surprised by it.

---
*Standard Version: 1.0 — the shared PHP rubric. Built to by the php-developer (via build-core); reviewed against by the php-reviewer. Generic security lives in standard-security; clean-code, performance, testing, and observability in their own standards.*
