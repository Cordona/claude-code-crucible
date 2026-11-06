# Security: development

## Reporting

- **No SCA scanner in the repo's CI** (A03): record the `scan` step as not run, with the stack's scanner to add.
- **A secret that needs revocation and rotation** (A02): record it, with where it is: its location when **found in source**, the commit holding it when **found only in git history**, or the last commit holding it when **your change removes it from source**.

## Self-check before reporting

1. Every path from a source to a sink you wrote or changed has that sink's control (Taint model), and no framework safe default is bypassed.
2. Untrusted input is validated server-side at every boundary, every grant is the least needed, every check denies by default, and all crypto uses vetted primitives.
3. Every protected operation is authorized at the resource, server-side; no privilege comes from untrusted data; CSRF, SSRF, redirect targets and file paths have their A01 controls; every access-granting id is unguessable.
4. No secret is hardcoded, committed or on a command line; every secret is fetched from a secret manager, and an environment variable only passes an already-fetched one to a child process; configuration, CORS, headers and cookies meet A02; dependencies and CI meet A03.
5. Passwords, randomness, IVs, encryption at rest and in transit, and certificate checks meet A04; every query, shell call, output, template and XML parser meets A05.
6. Sensitive flows are rate-limited with per-account backoff; request, collection, decompression and regex costs are bounded; uploads are type-checked, capped and stored under generated names; business rules run server-side; PII is minimal, erasable, anonymized irreversibly and kept only for its retention period.
7. Sessions, tokens, MFA and password policy meet A07, and deserialization and merged keys meet A08; every security check fails closed on error, no error response leaks internals, and the project's security controls were followed without excusing an exploitable vulnerability.

A new dependency's lock entry comes with its install: the lock rule (A03) holds for the dependencies already installed.
