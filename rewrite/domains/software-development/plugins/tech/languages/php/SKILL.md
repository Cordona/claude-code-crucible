---
name: language-php
description: "PHP rules: toolchain, type juggling, null and array access, decoding, exhaustiveness, exceptions, strict types and lints, plus the developer's verification gate. Use when writing or reviewing PHP. A language plugin. Its gate writes only tool caches and what the project's tests write; needs `php`, `composer` and the `vendor/bin` tools. Not for PHP driven only from another file, Laravel's own rules (`framework-laravel`), or rules every language shares (`code-developer`, standard plugins)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: PHP
---

# Language: PHP

The rules that are specific to PHP. Every role receives this file in its first message. A developer then receives `references/development.md` right after it: what to report, the defaults, the edge cases and the verification gate. A reviewer receives `references/review.md` right after it instead: how to judge a finding and how to grade it.

## Scope

- **In:** PHP applications, REST APIs, queue jobs and console commands.
- **In:** code on a web framework with no plugin of its own, such as Symfony, Slim or Laminas: this file holds no rules for the framework itself.
- **In:** legacy PHP, before 8.0: it lacks the features of Strict typing and modern idioms below, and its type juggling needs a harder look.
- **Out:** PHP driven only from another file, such as a Dockerfile `RUN composer install` line or a CI step.
- **Out:** Laravel's own rules: `framework-laravel`, when loaded beside this one, holds them.

## Toolchain

Settle it before writing a line. Take each fact from the first source below that sets it:

1. The PHP version: `composer.json`'s `require.php` and `config.platform.php`; else `composer.lock`; else `.tool-versions`.
2. The commands: the project's own `test`, `lint` and `format` scripts in `composer.json`, over raw tool commands.
3. The tools configured: PHPStan (`phpstan.neon` or `phpstan.neon.dist`), Psalm (`psalm.xml`), php-cs-fixer (`.php-cs-fixer.php` or `.php-cs-fixer.dist.php`), phpcs (`phpcs.xml` or `phpcs.xml.dist`), Pint (`pint.json`).
4. What the project's own docs on its PHP code say, where the task's context lists them.
5. Otherwise PHP 8.4 (see Version ledger).

## Type juggling and comparisons

- **`===` and `!==`, never loose `==` or `!=`:** loose comparison juggles types (`0 == "abc"`, `"1e3" == "1000"`, `"" == null`), so a logic- or security-sensitive comparison with `==` is a bug.
- **Pass strict mode to the comparison built-ins:** `in_array($needle, $haystack, true)` and `array_search($needle, $haystack, true)`.
- **Compare floats with an epsilon (`abs($a - $b) < $epsilon`), never `==` or `===`; use `bccomp` instead when the values are decimal strings that need exact precision:** `0.1 + 0.2 === 0.3` is `false`, so strict comparison doesn't rescue it.

## Null and array access

- **An undefined array key or property is a bug, not a default:** guard access with `isset`, `array_key_exists` or `??`, and read only a key you have proven present.
- **Use `?->` only where null is a valid result:** a null-safe chain that short-circuits on a required value hides the defect instead of surfacing it.
- **Use `??` only for an optional value:** a default for a required value turns a loud failure into silent wrong behaviour.

## Boundary decoding

- **Decode JSON strictly at the boundary:** bare `json_decode($s)` returns `null` for both invalid JSON and a literal `null`, so use `json_decode($s, flags: JSON_THROW_ON_ERROR)`; call `json_validate()` first only when you need validity without the decoded value; the PHP version `json_validate()` needs is in the Version ledger.
- **`tryFrom()` for untrusted or database-sourced input to a backed enum:** `from()` throws `\ValueError` on an unknown value, so keep it for values already known valid.

## Exhaustiveness

- **`match` over `switch`:** `switch` falls through on a missing `break`; `match` compares strictly and throws `UnhandledMatchError` on an unhandled value.
- **A `match` over an enum has no `default`:** a newly added case then fails loudly, where a `switch` or a swallowing `default` hides the gap.

## Arithmetic

- **Integer overflow silently becomes a `float`:** `PHP_INT_MAX + 1` loses integer precision instead of wrapping or failing, so guard size, index and money math that can pass the bounds.
- **An overflow with a security consequence** (fraud, over-allocation, an out-of-bounds index) is a correctness defect with a security harm, not only arithmetic.

## Exceptions

- **No empty `catch`, and no `catch (\Throwable)` that swallows unrelated failures:** catch the specific exception you can handle.

## PHP mechanisms for the shared standards

- **Queries:** PDO prepared statements with bound parameters, never SQL built by concatenation.
- **Output:** a value written into HTML is escaped with `htmlspecialchars`.
- **Deserialization:** never `unserialize()` on untrusted input.
- **Code execution:** never `eval()`, `create_function`-style dynamic code, or an `include`/`require` path on untrusted input.
- **Supply chain:** `composer audit`, and pinned dependencies; the audit is no gate step, since it needs the network.
- **Logging:** Monolog or another PSR-3 logger, with structured context.
- **Docs:** PHPDoc on a public item only when its signature can't state a constraint, a failure condition or behaviour beyond it, such as `list<Foo>`, `non-empty-string` or `@throws`.

## Strict typing and modern idioms

- **`declare(strict_types=1)` in every new file:** without it PHP coerces argument and return types silently.
- **Type every property, parameter and return,** with union and intersection types where they fit; no `mixed` where a real type fits.
- **Type returns honestly:** `?T` only when null is a real result, `never` for a function that never returns.
- **Constructor property promotion, `readonly` for value objects, enums for fixed sets, and `#[\Override]` on an override;** the PHP version each needs is in the Version ledger.

## Language micro-performance

- **No regex pattern recompiled inside a loop:** hoist the `preg_*` pattern out of it.
- **No per-element object or closure overhead on a hot path:** use `array_map`, `array_filter`, `array_reduce` or a plain loop.
- **No `eval()` or dynamic `include` path:** either defeats OPcache.

## Lints

- **Syntax-check with no new error:** treat each one your change adds as a gate failure. Old ones in an existing project would otherwise fail every change.
- **PHPStan (Larastan included) or Psalm, at the project's configured level, with no new error:** treat each one your change adds as a gate failure. Old ones in an existing project would otherwise fail every change.
- **Take the gate's baseline on top of a project's `phpstan-baseline.neon`:** it is part of the project's PHPStan config.
- **Honor php-cs-fixer, phpcs (PSR-12) or Pint where the project configures them,** with no new finding.
- **Name each finding by its rule id** (PHPStan's error identifier, Psalm's issue type, the php-cs-fixer or phpcs rule): a finding with no id can't be matched against the baseline the gate compares to.
- **Every `@phpstan-ignore`, `@phpstan-ignore-next-line`, `@phpstan-ignore-line`, `@psalm-suppress` and `phpcs:ignore` carries its written reason:** a reasoned one on a line complies; an unexplained one is a defect.
- **No rule turned off or down in the project's lint config:** such a change is a defect.

## Version ledger

| Fact | Value | Last verified |
|---|---|---|
| Default PHP version (Toolchain step 5) | 8.4 | not verified by a command: the legacy default, kept on 2026-10-31 |
| Latest stable PHP | 8.5.12 | 2026-10-31, `brew info --json=v2 php`, macOS 27.2 |
| `json_validate()` available from | PHP 8.3 | not verified by a command: the legacy value, kept on 2026-10-31 |
| Constructor property promotion available from | PHP 8.0 | not verified by a command: no legacy source gives it, kept on 2026-10-31 |
| `#[\Override]` available from | PHP 8.3 | not verified by a command: no legacy source gives it, kept on 2026-10-31 |
| Enums and `readonly` properties available from | PHP 8.1 | not verified by a command: no legacy source gives it, kept on 2026-10-31 |
