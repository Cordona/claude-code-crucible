---
name: framework-laravel-build
description: "Laravel rules for a build job agent, preloaded through its agent file. Not for main."
user-invocable: false
metadata:
  label: Laravel, build
---

# Laravel: build

## Defaults when nothing given says otherwise

- **New request input** is validated in a FormRequest.
- **A new resource** is authorized through a Policy.
- **A new model** sets `$fillable`; `$guarded` only where the project's models already use it.
- **A large read** uses `lazy()`; `chunk()` or `cursor()` only where the project already reads that way.
- **A job that can't be idempotent** uses `ShouldBeUnique`; an idempotency key only where the job writes to an outside system that accepts one, such as a payment provider.

## Edge cases

- **A controller action or route the task touches with no authorization check:** record it, unless the task covers authorization.
- **A model with `$guarded = []` that the task reads but doesn't change:** record it; don't search for others.
