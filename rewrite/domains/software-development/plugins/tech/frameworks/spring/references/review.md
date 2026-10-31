# Spring: review

Apply with `SKILL.md`'s rules when judging Spring code, beside the language plugin's review rules: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness, and with this plugin loaded it judges Spring correctness too.** Check for:
  - a self-invoked `@Transactional` method relied on for a transaction;
  - a lazy association loaded outside the transaction;
  - a Kotlin class Spring proxies or JPA instantiates without the all-open or no-arg plugin, and no `noticed` entry for it.

## How to judge

- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **Verify a Spring API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a Spring defect usually lands on the four levels. Start here, then judge the case in front of you. It places Spring defects, its security and accessibility forms included; the language plugin's Severity grades the language rules.

- **CRITICAL:**
  - exploitable injection: untrusted input spliced into a query's text, against `SKILL.md`'s Queries mechanism.
- **HIGH:**
  - a correctness defect from Correctness above;
  - a path a rule leaves open (no `denyAll` where `SKILL.md`'s Deny-by-default rule calls for it, or a broad matcher before a narrow one);
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

**Overrides:** none.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- Injection and remote code execution drop to HIGH when exploiting them is harder or reaches less.
- A fail-open check, client-side data exposure and XSS drop to MEDIUM when exploiting them is harder or reaches less.
- CSRF off rises to HIGH on a critical flow (login, payment, an account change).
