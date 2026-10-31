# Laravel: review

Apply with `SKILL.md`'s rules when judging Laravel code, beside the language plugin's review rules: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness, and with this plugin loaded it judges Laravel correctness too.** Check for:
  - a relation the code walks with no eager load where `preventLazyLoading()` is on, so the read throws;
  - `env()` called outside `config/`, so it returns `null` once the configuration is cached.

## How to judge

- **Judge observable behaviour, not the framework's internals or facade magic:** a facade, a magic method or a container binding is judged by what the code does, never by how Laravel resolves it.
- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **Verify a Laravel API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a Laravel defect usually lands on the four levels. Start here, then judge the case in front of you. It places Laravel defects, its security and accessibility forms included; the language plugin's Severity grades the language rules.

- **CRITICAL:**
  - a transaction that can commit partial state: a non-atomic multi-write with no compensation;
  - exploitable injection: untrusted input in the SQL text of a raw query method, against `SKILL.md`'s Output and queries section.
- **HIGH:**
  - a correctness defect from Correctness above;
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
- **LOW:** none of its own.

**Overrides:** none.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- Injection and remote code execution drop to HIGH when exploiting them is harder or reaches less.
- A fail-open check, client-side data exposure and XSS drop to MEDIUM when exploiting them is harder or reaches less.
- CSRF off rises to HIGH on a critical flow (login, payment, an account change).
