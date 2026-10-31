# Laravel: development

Apply after `SKILL.md`'s rules, beside the language plugin's development rules, before writing any Laravel code.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The Laravel version found** -> the report's `toolchain`, beside the language toolchain, because the reviewer judges the code against the Laravel version it names.
- **The `verification` items are the language plugin's gate items:** this plugin adds none.

## Defaults when the first message is silent

- **The Laravel version** comes from `SKILL.md`'s Toolchain order.
- **New request input** is validated in a FormRequest.
- **A new resource** is authorized through a Policy.
- **A new model** sets `$fillable`; `$guarded` only where the project's models already use it.
- **A large read** uses `lazy()`; `chunk()` or `cursor()` only where the project already reads that way.
- **A job that can't be idempotent** uses `ShouldBeUnique`; an idempotency key only where the job writes to an outside system that accepts one, such as a payment provider.

## Edge cases

- **A controller action or route the task touches with no authorization check:** record it in the report's `noticed`, unless the task covers authorization.
- **A model with `$guarded = []` that the task doesn't touch:** record it in the report's `noticed`.

## Verification gate

The language plugin's gate covers Laravel code: its format, syntax and lint steps, Pint and Larastan included where the project configures them, and the existing tests. This plugin adds no step and no tool.

## Self-check before reporting

1. Every touched controller action or route that acts on a user's data is authorized through a Policy or a Gate, or the missing check is in `noticed`.
2. Every model the change adds or edits sets `$fillable` or `$guarded`, and no unvalidated request input reaches a model whole.
3. Request input is validated at the boundary, and only `validated()` data flows past it.
4. No untrusted input reaches `{!! !!}` or the SQL text of a raw query method.
5. Each relation the code walks is eager-loaded.
6. Each unit of work's writes share one `DB::transaction()` closure.
7. The report's `toolchain` names the Laravel version settled in `SKILL.md`'s Toolchain order, and every other item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
