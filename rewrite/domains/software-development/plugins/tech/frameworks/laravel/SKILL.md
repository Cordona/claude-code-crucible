---
name: framework-laravel
description: "Laravel rules: toolchain, authorization, mass assignment, Blade output and raw queries, validation, CSRF, configuration, Eloquent loading, transactions and queued jobs. Use when writing or reviewing PHP that uses Laravel. A framework plugin beside its language plugin. Writes nothing and adds no gate tool. Not for code with no language plugin loaded, other PHP frameworks (Symfony, Slim, Laminas), or PHP's own rules (`language-php`)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: Laravel
---

# Framework: Laravel

The rules that are specific to Laravel. It loads beside `language-php`, never alone, and repeats no rule that plugin holds. Every role receives this file in its first message, after the language plugin's. A developer then receives `references/development.md` right after it: what to report, the defaults, the edge cases and the verification gate. A reviewer receives `references/review.md` right after it instead: how to judge a finding and how to grade it.

## Scope

- **In:** Laravel applications, used from PHP: routes, controllers, Eloquent models, migrations, queued jobs, Blade templates and artisan commands.
- **Out:** Laravel code with no language plugin loaded: this plugin never loads alone.
- **Out:** PHP's own rules: `language-php` holds them.
- **Out:** other PHP frameworks, such as Symfony, Slim or Laminas: this file holds no rules for them.

## Toolchain

Settle it after the language plugin's toolchain, before writing a line. Take each fact from the first source below that sets it:

1. The `laravel/framework` version in `composer.lock`, else its constraint in `composer.json`.
2. What the project's own docs on its Laravel code say, where the task's context lists them.
3. Otherwise Laravel 12 (see Version ledger).

## Output and queries

- **Echo with Blade's `{{ }}`, and use `{!! !!}` only on HTML the application built or sanitized:** `{{ }}` escapes, while `{!! !!}` prints raw, so untrusted input there is XSS.
- **Keep untrusted input out of the SQL text of `DB::raw`, `whereRaw`, `selectRaw` and `orderByRaw`,** passing it as a bound parameter: these methods put their string into the query as written.

## Transactions

- **Group the writes of one unit of work in a `DB::transaction()` closure:** it commits when the closure returns and rolls back only when an exception leaves it, so an exception caught inside commits the partial work.
- **Scope the closure tight,** to the writes that must be atomic: the transaction holds its locks and its connection until the closure returns.

## Authorization

- **Authorize every controller action or route that acts on a user's data,** through a Policy or a Gate (`$this->authorize()`, `Gate::authorize()`, the `can` middleware): anyone who knows a route's URL can call it, so a hidden link is no control.
- **Scope route model binding to its parent where the resource is nested** (`scopeBindings()`): otherwise `/users/{user}/posts/{post}` resolves any post, whoever owns it.

## Mass assignment

- **Set `$fillable` or `$guarded` on every model:** it decides which attributes `create()`, `fill()` and `update()` take from an array.
- **Never pair `$guarded = []` with request input passed whole** (`$request->all()`): the client can then set any column, `is_admin` or `user_id` included.

## Validation

- **Validate request input at the boundary, with a FormRequest or `$request->validate()`:** a rule that never runs checks nothing.
- **Use only `validated()` data downstream:** `$request->all()` also carries every field the rules never checked.

## Configuration

- **Call `env()` only inside `config/`, and read settings everywhere else with `config()`:** once the configuration is cached, `env()` outside `config/` returns `null`.

## Queued jobs

- **Make a job that may run twice idempotent:** a queue retries a failed or timed-out job, so it can run more than once.
- **Where a job can't be idempotent, use `ShouldBeUnique` or an idempotency key checked before the write:** a retry then finds the work done.

## Eloquent loading

- **Eager-load with `with()` every relation the code walks:** a lazy relation read in a loop runs one query per row.
- **Where the project enables `Model::preventLazyLoading()` outside production, keep it on:** it turns a missed `with()` into an exception before the code ships.
- **Read a large table with `chunk()`, `lazy()` or `cursor()`:** `get()` and `all()` load every row into memory at once.

## CSRF

- **Keep the CSRF middleware on for web routes:** a form a signed-in browser posts is otherwise forgeable from another site.

## Laravel mechanisms for the shared standards

- **Queries:** Eloquent or the query builder, every value bound; `standard-security` holds the injection rule this meets, loaded only when the task's plan loads it.
- **Persistence:**
  - `DB::transaction()` boundaries scoped tight;
  - `with()` over a relation walked per row;
  - `chunk()` or `lazy()` for large reads;
  - migrations written expand-contract: add the new column or table first, drop the old one in a later release;
  - `$casts` for typed attributes, such as dates, enums and booleans;
  - `standard-persistence` holds the store-agnostic rules these meet, loaded only when the task's plan loads it.
- **Logging:** the `Log` facade, with structured context passed as its context array.

## Lints

- **Laravel adds no lint of its own:** Larastan, where the project configures it, runs as the language plugin's PHPStan step, and the language plugin's Lints apply.

## Version ledger

| Fact | Value | Last verified |
|---|---|---|
| Default Laravel major (Toolchain step 3) | 12 | not verified by a command: the legacy default, kept on 2026-10-31 |
| Latest stable Laravel | 13.39.0 | 2026-10-31, `curl -s https://repo.packagist.org/p2/laravel/framework.json`, macOS 27.2 |
