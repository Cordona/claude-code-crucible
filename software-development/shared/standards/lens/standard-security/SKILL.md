---
name: standard-security
description: The single definition of secure code — the shared rubric that developers BUILD to and the security lens REVIEWS against. Applies whenever code handles untrusted input, authentication/authorization, secrets, queries, crypto, external calls, deserialization, or privileged operations in any language. Grounded in OWASP Top 10:2025, ASVS 5.0, and the CWE Top 25. Defines the taint model (source→sink→control), boundary input validation, injection prevention, secrets handling, auth/session/JWT, least-privilege authorization, safe cryptography, transport security, fail-secure error handling, SSRF/XXE/open-redirect/CSRF/mass-assignment/deserialization, security misconfiguration, and supply-chain integrity. This is WHAT good looks like; it does not define builder workflow (build-core), the reviewer's threat-surface gate / taint-trace procedure / severity / vocabulary (the lens), language memory-safety mechanics (the {tech} pair), or security logging (observability).
---

# Standard: Security

The **one** definition of secure code. Developers build to it (security in from the first line, not patched after a pentest); the `lens-security-reviewer` judges against it. Both bind this single skill, so there is no daylight between how we build and how we review. **Security is non-negotiable — never trade it for convenience.**

Grounded in **OWASP Top 10:2025**, **ASVS 5.0**, and the **CWE Top 25**. Reason in **categories** — the weakness class is portable; the manifestation adapts to the target's stack. Assurance scales with exposure (ASVS **L1** = every app · **L2** = auth/PII/payments · **L3** = high-assurance: finance/health/infra).

This skill defines **WHAT good looks like**. It does NOT contain: the builder's workflow (`build-core`); the reviewer's machinery (the threat-surface *gate procedure*, the taint-*trace* steps, severity, `category` vocabulary, false-positive guards — those live in the lens); **language memory-safety mechanics** (buffer overflow, use-after-free — the `{tech}` pair); or **security logging / audit** (observability).

## Think in taint (the model)

Untrusted data (a request, a file, an upstream response, an env value) flows from a **source** to a dangerous **sink** (a query, a shell, a template, a file path, an outbound URL, a deserializer). Put a **control** — validation, parameterization, encoding, authorization — on **every** such path. Two rules:
- **Input validation ≠ output encoding.** Each sink needs its *own* sink-specific defense; validating on the way in does not make the sink safe.
- **A framework's safe default IS the control** (ORM binding, auto-escaping template, prepared statement). Use it — the weakness appears only when it is bypassed (raw/unsafe APIs, disabled escaping).

## Cross-cutting foundations

- **Validate untrusted input at every boundary** — API endpoints, form input, file uploads, message consumers, external-service responses, config loading. Prefer **allow-lists** (known-good shapes) over deny-lists; enforce type, range, length, format; reject early with a guard clause; validate **server-side** (never trust client checks alone) (CWE-20).
- **Least privilege** — request and grant the minimum scope/permission needed, everywhere (identities, tokens, file modes, IAM, DB grants).
- **Never roll your own crypto** — use vetted standard-library primitives.
- **Fail secure** — deny by default; an exception in a security check must never fall through to "allowed."

## The control set (by OWASP Top 10:2025 category, with CWE anchors)

### A01 — Broken Access Control (+ SSRF, open redirect, CSRF, mass assignment)
- **Authorize every protected operation at the resource/function**, server-side, deny-by-default — check the caller may act on *this* resource; don't assume an earlier layer or gateway did. Missing object/function-level checks → IDOR (CWE-862/863).
- **No privilege from untrusted data** — never derive a role/privilege from a request field, an unverified token claim, or a request body **auto-bound to protected fields** (`isAdmin`, `ownerId`, `balance`) → mass assignment / privilege escalation (CWE-269/915). Bind only the fields the caller may set.
- **CSRF** — state-changing browser-facing endpoints need an anti-CSRF token / `SameSite` / origin check (CWE-352).
- **SSRF** — for any server-side fetch of a user-controlled URL: **host allow-list**, block internal/link-local/metadata ranges (`169.254.169.254`, `127/8`, `10/8`, `172.16/12`, `192.168/16`, `::1`), restrict scheme, no redirect-follow (CWE-918).
- **Open redirect** — never redirect/forward to a user-supplied target without an allow-list (CWE-601): phishing, OAuth token theft.

### A05 — Injection
- **Parameterized queries / prepared statements ALWAYS** — never build SQL/NoSQL/LDAP/XPath by concatenation/interpolation with untrusted input (CWE-89).
- **No untrusted input to a shell/eval** — avoid dynamic command execution; if unavoidable, pass command and args **separately as an array**, never a concatenated shell string (CWE-78).
- **Contextual output encoding** — encode/escape data for its *output* context (HTML body/attribute, JS, URL) to neutralize XSS at the sink (CWE-79); watch `innerHTML`, `dangerouslySetInnerHTML`, disabled auto-escape, `| raw`/`| safe`.
- **No `eval` / dynamic code / template injection** on request data (CWE-94 / SSTI).
- **XXE** — disable external-entity and DTD processing in XML parsers (CWE-611): file read, SSRF, RCE.

### A08 — Software & Data Integrity / Deserialization
- **Never deserialize untrusted data into arbitrary types** → RCE (CWE-502): Java `ObjectInputStream`/`readObject`, Python `pickle`/`yaml.load`, PHP `unserialize`, .NET `BinaryFormatter`, Ruby `Marshal.load`, JS prototype pollution.
- **Verify integrity** — artifacts/plugins/auto-updates loaded only with signature/checksum verification.

### A04 — Cryptographic Failures
- **Vetted primitives only** — no MD5/SHA-1 for security, no DES/RC4/ECB, no home-grown crypto.
- **Password hashing:** strong adaptive algorithm — prefer **Argon2id** (scrypt/bcrypt/PBKDF2 as alternatives; bcrypt only for legacy or ≤72-byte constraints). Never fast/unsalted hashes.
- **Randomness & keys:** a **CSPRNG** for tokens/IDs/secrets (never `Math.random`/`rand`); no hardcoded/static keys or IVs, no reused nonces; authenticated encryption for data.
- **Transport:** require TLS; **never disable certificate verification** (`verify=false`, `InsecureSkipVerify`, trust-all managers) outside a controlled test. No sensitive data in plaintext.

### A07 — Authentication & Session
- **Sessions:** issue a fresh session/token on login and on privilege change; set an expiry; invalidate on logout. **Never place a session token in a URL.**
- **Token validation:** for JWTs/signed tokens verify the signature, reject `alg:none` and algorithm-confusion, and check `exp`/`iss`/`aud`. Never trust an unverified token's claims.
- **Anti-automation:** lockout/backoff on repeated failed logins; MFA where risk warrants (expected at L2+).

### A02 — Security Misconfiguration + Secrets
- **Secrets:** never hardcode secrets/keys/credentials/connection strings in source or committed config (CWE-798) — load from env or a secret manager (Vault, cloud secret store). Never pass a secret on a command line (visible in `ps`); never commit one. *(If found in git history: revoke + rotate. Secrets in **logs** → observability.)*
- **No verbose exposure in production** — no debug errors, stack traces, or directory listing reachable in prod.
- **Web surface:** no permissive CORS (`*` with credentials, or reflected origin); set the standard security headers; session cookies carry `Secure`, `HttpOnly`, and an appropriate `SameSite`.
- **Least-privilege config:** no `chmod 777` / wildcard IAM / public buckets / run-as-root; no default accounts/ports left enabled.

### A03 — Software Supply Chain
- **Pin + lock** dependency versions (commit a lockfile); prefer maintained, official packages; no known-vulnerable/unmaintained components.
- **Scan** — recommend SCA in CI (`npm/pip/cargo audit`, `govulncheck`, OWASP Dependency-Check) + an SBOM; the transitive CVE tree is a scanner's job, not eyeballing.
- **CI hygiene** — no unpinned external scripts/actions (`curl | bash`, unpinned action SHAs).

### A06 — Insecure Design
- **Rate-limit / anti-automation** on security-sensitive flows (login, OTP, password-reset, payment, token issuance) and expensive/abusable endpoints.
- **Fail closed, server-side** — business rules (limits, ownership, workflow state) enforced on the server, never only client-side; the design must fail closed, not open.

### A10 — Mishandling of Exceptional Conditions (security aspect)
- **Fail closed on error** — a security check that defaults to ALLOW on exception/timeout (authz lookup throws → access granted) is a vulnerability; require fail-closed.
- **No internal leakage** — error responses to callers must not leak stack traces, SQL, internal paths, or secrets; log the detail internally (observability), return a generic message.

## Security consistency

Conform to the project's established security controls (auth pattern, validation/encoding approach, secret handling); new code should not bypass an existing safe pattern. But a genuinely exploitable vulnerability is a vulnerability — project "convention" never launders it.

---
*Standard Version: 1.0 — the shared security rubric, grounded in OWASP Top 10:2025 / ASVS 5.0 / CWE Top 25. Built to by developers (via build-core); reviewed against by lens-security-reviewer. Memory-safety mechanics live in the {tech} pair; security logging in observability.*
