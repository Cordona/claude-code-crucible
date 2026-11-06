# Laravel: review

## Correctness

- **Check for these Laravel correctness defects:**
  - a relation the code walks with no eager load where `preventLazyLoading()` is on, so the read throws;
  - `env()` called outside `config/`, so it returns `null` once the configuration is cached.

## How to judge

- **Judge observable behaviour, not the framework's internals or facade magic:** a facade, a magic method or a container binding is judged by what the code does, never by how Laravel resolves it.

## Severity

- **CRITICAL:**
  - a transaction that can commit partial state: a non-atomic multi-write with no compensation;
  - exploitable injection: untrusted input in the SQL text of a raw query method, against `SKILL.md`'s Output and queries section.
- **HIGH:**
  - a controller action or route that acts on a user's data with no authorization check, or a nested route whose model binding isn't scoped to its parent (broken access control);
  - mass assignment onto a protected field: request input passed whole to a model with `$guarded = []` or no `$fillable`;
  - `{!! !!}` on untrusted input (XSS);
  - unvalidated request input used whole: no FormRequest or `validate()` at the boundary, or `$request->all()` where `validated()` belongs (a check that fails open);
  - a queued job that isn't idempotent, with no `ShouldBeUnique` or idempotency key;
  - a migration that breaks running code mid-rollout (no expand-contract).
- **MEDIUM:**
  - CSRF off for web routes;
  - a lazy-loaded relation walked per row;
  - an unbounded read of a large table.

**What moves a level:**
- CSRF off rises to HIGH on a critical flow (login, payment, an account change).
