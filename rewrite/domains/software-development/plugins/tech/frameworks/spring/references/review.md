# Spring: review

## Correctness

- **Check for these Spring correctness defects:**
  - a self-invoked `@Transactional` method relied on for a transaction;
  - a lazy association loaded outside the transaction;
  - a Kotlin class Spring proxies or JPA instantiates without the all-open or no-arg plugin, and the needed change not recorded.

## Severity

- **CRITICAL:**
  - exploitable injection: untrusted input spliced into a query's text, against the Queries mechanism.
- **HIGH:**
  - a path a rule leaves open (no `denyAll` where the Deny-by-default rule calls for it, or a broad matcher before a narrow one);
  - a `@PreAuthorize` that never runs (no `@EnableMethodSecurity`, or a self-invocation);
  - a password stored in plain text or through `NoOpPasswordEncoder`;
  - a constrained request body with no `@Valid` at the controller boundary, so its constraints never run (a check that fails open);
  - an error response that returns a stack trace to the client (sensitive data exposed).
- **MEDIUM:**
  - `@Transactional` on a controller or repository;
  - eager fetch on a collection;
  - CSRF off for a browser session.
- **LOW:**
  - field `@Autowired`.

**What moves a level:**
- CSRF off rises to HIGH on a critical flow (login, payment, an account change).
