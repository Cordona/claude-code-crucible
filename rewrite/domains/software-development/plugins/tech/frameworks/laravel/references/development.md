# Laravel: development

## Defaults when nothing given says otherwise

- **New request input** is validated in a FormRequest.
- **A new resource** is authorized through a Policy.
- **A new model** sets `$fillable`; `$guarded` only where the project's models already use it.
- **A large read** uses `lazy()`; `chunk()` or `cursor()` only where the project already reads that way.
- **A job that can't be idempotent** uses `ShouldBeUnique`; an idempotency key only where the job writes to an outside system that accepts one, such as a payment provider.

## Edge cases

- **A controller action or route the task touches with no authorization check:** record it, unless the task covers authorization.
- **A model with `$guarded = []` that the task doesn't touch:** record it.

## Self-check before reporting

1. Every touched controller action or route that acts on a user's data is authorized through a Policy or a Gate, or the missing check is recorded.
2. Every model the change adds or edits sets `$fillable` or `$guarded`, and no unvalidated request input reaches a model whole.
3. Request input is validated at the boundary, and only `validated()` data flows past it.
4. No untrusted input reaches `{!! !!}` or the SQL text of a raw query method.
5. Each relation the code walks is eager-loaded.
6. Each unit of work's writes share one `DB::transaction()` closure.
