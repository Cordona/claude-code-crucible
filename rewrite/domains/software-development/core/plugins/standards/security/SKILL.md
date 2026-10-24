---
name: standard-security
description: The security rubric for code in any language, tests included, that handles untrusted input, auth, secrets, queries, crypto, outbound calls, deserialization or sensitive data — a taint model, foundations and controls grouped by OWASP A01–A10. Injected into the agent's first message when loaded. Writes nothing. Not for logging or audit (standard-observability), store correctness (standard-persistence), test-only rules (standard-testing) or memory safety (its tech plugin).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Security
---

# Standard: Security

What secure code holds, in any language. Security is non-negotiable: never trade it for convenience. Build security in from the first line: never leave it to be patched after a pentest. The developer builds to these rules, then follows `references/development.md`; a reviewer (once a review flow dispatches `code-reviewer`) judges by the same rules, then follows `references/review.md`. Both receive this file in their prompt (or by Read, implementing directly), with their role's reference file right after it.

It is grounded in OWASP Top 10:2025, ASVS 5.0, the CWE Top 25 and, for password policy, NIST SP 800-63B-4. Reason in weakness classes, which carry across stacks, and map each to how it shows up in the stack in front of you.

The ten numbered rule sections carry OWASP Top 10:2025's names, but which rule sits in which section is this standard's own grouping: OWASP may map a rule's weakness elsewhere, and the CWE id on a rule is the authority.

## Scope

- **In:** code the developer writes or changes, test code included, that handles untrusted input, authentication, sessions, authorization, secrets, queries, cryptography, outbound calls, deserialization, sensitive data or privileged operations, and the configuration, dependencies and CI that code ships with. A change that touches none of these is out.
- **Data protection beyond logs is in:** encryption at rest, PII minimization, erasure and retention.
- **Project conventions:** follow the project's security controls: its auth pattern, its validation and encoding approach, its secret handling. New code never bypasses an existing safe pattern. A convention never excuses an exploitable vulnerability: it is a defect even where the project does the same.

## Taint model

- **Put a control on every path from a source (a request, a file, an upstream response, an environment value) to a sink:** untrusted data that reaches a sink uncontrolled is the weakness.
- **Give each sink its own control:** input validation is not output encoding, and validating on the way in never makes a sink safe.
- **A framework's safe default is the control** (ORM binding, an auto-escaping template, a prepared statement): use it. The weakness appears only where code bypasses it, through a raw or unsafe API or disabled escaping.

The default control for each sink:

| Sink | Control | Rule |
|---|---|---|
| Query | Parameterize | A05 |
| Shell command | Pass command and arguments as an array | A05 |
| HTML output | Contextual encoding | A05 |
| File path | Map a server-side id to a fixed path | A01 (CWE-22) |
| Outbound URL | Host allow-list | A01 |
| Deserializer | Allow-list of safe types | A08 |

## Foundations

- **Validate untrusted input at every boundary, server-side,** an upstream service's response, a message, a file upload and config or environment values included: a client-side check is never the control (CWE-20).
- **Prefer allow-lists of known-good shapes to deny-lists.**
- **Check type, range, length and format, and reject invalid input early** with a guard clause.
- **Least privilege everywhere:** request and grant only the scope or permission the task needs, for identities, tokens, file modes, IAM and database grants.
- **Never roll your own crypto:** use the standard library's vetted primitives (A04).
- **Fail closed: deny by default.** A06 holds the design form and A10 the error-path form.

## 1. Broken access control (OWASP A01)

- **Authorize every protected operation at the resource or function, server-side and deny-by-default:** check that the caller may act on this resource, and never assume an earlier layer or a gateway did. A missing or wrong check is CWE-862 or CWE-863; reaching an object by a user-controlled id without that check is IDOR (CWE-639).
- **Authorization is always the IDOR control:** an id's shape never replaces the check.
- **Require an unguessable CSPRNG id only where the id itself grants access,** such as a share link.
- **No privilege from untrusted data:** never derive a role or privilege from a request field, an unverified token claim or a body auto-bound to protected fields (`isAdmin`, `ownerId`, `balance`); bind only the fields the caller may set (mass assignment, CWE-269, CWE-915).
- **Protect every state-changing, browser-facing endpoint against CSRF** with the framework's anti-CSRF token plus `SameSite=Lax` cookies (CWE-352).
- **A server-side fetch of a user-controlled URL takes every SSRF control** (CWE-918):
  - a host allow-list;
  - a block on at least these internal, loopback, link-local, metadata, shared, multicast, reserved and broadcast IPv4 ranges: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` (the metadata address `169.254.169.254` among them), `100.64.0.0/10` (shared address space, holding Alibaba Cloud's metadata address `100.100.100.200`), `0.0.0.0/8`, `224.0.0.0/4`, `240.0.0.0/4` and `255.255.255.255/32`;
  - a block on the IPv6 loopback, unspecified, link-local, unique-local and multicast ranges: `::1`, `::/128`, `fe80::/10`, `fc00::/7` and `ff00::/8`;
  - a block on every IPv6 range that can embed an IPv4 address: IPv4-mapped `::ffff:0:0/96`, NAT64 `64:ff9b::/96` and `64:ff9b:1::/48`, 6to4 `2002::/16` and Teredo `2001::/32`;
  - a block on every resolved address that is not public unicast, listed above or not;
  - the block checks the resolved address the connection uses, not the hostname, so DNS rebinding can't swap the address after the check;
  - only the schemes it needs;
  - no redirect following.
- **Never redirect or forward to a user-supplied target without an allow-list** (CWE-601): an open redirect serves phishing and OAuth token theft.
- **Never build a file path from user input:** map a server-side id to a fixed path and reject every other value (path traversal, CWE-22).
- **Where a user-supplied file name is unavoidable,** check it against a strict character allow-list, canonicalize it (resolving `..` and symlinks), then confirm the result is still inside the allowed base directory before opening it.
- **Never extract an archive entry to the path the archive stores without the same base-directory check:** a stored `../` path writes outside the target directory (zip slip, CWE-22).

## 2. Security misconfiguration (OWASP A02)

- **Never hardcode a secret** (a key, credential, token or connection string) in source or committed config (CWE-798).
- **Fetch every secret from a secret manager;** use an environment variable only to pass an already-fetched secret to a child process, never to store one, and a file with mode 600 when the child must not inherit it.
- **Never pass a secret on a command line:** every user on the host can read it in `ps`.
- **Never commit a secret.**
- **Revoke and rotate a secret found in git history.**
- **No debug mode or directory listing reachable in production.**
- **No permissive CORS:** never `*` with credentials, and never a reflected origin.
- **Set the security headers:** `Content-Security-Policy` with `frame-ancestors`, `Strict-Transport-Security` and `X-Content-Type-Options: nosniff`.
- **Session cookies carry `Secure`, `HttpOnly` and `SameSite=Lax`;** use `SameSite=Strict` on a payment, account recovery, or a credential or permission change.
- **Least-privilege configuration:** no `chmod 777`, wildcard IAM policy, public bucket or run-as-root, and no default account or port left enabled.

## 3. Software supply chain failures (OWASP A03)

- **Pin and lock every dependency version;** the lockfile is committed.
- **Never ship a known-vulnerable or unmaintained component.**
- **Leave the transitive CVE tree to a scanner:** an SCA tool in CI (`npm audit`, `cargo audit`, `govulncheck` or OWASP Dependency-Check, by stack) plus an SBOM.
- **CI runs nothing unpinned:** no `curl | bash`, and every third-party action pinned to a commit SHA.

## 4. Cryptographic failures (OWASP A04)

- **Use vetted primitives only:** no MD5 or SHA-1 for a security purpose, and no DES, RC4 or ECB mode.
- **Hash passwords with Argon2id;** use scrypt only where Argon2id is unavailable, PBKDF2 only where FIPS compliance is required, and bcrypt only in legacy code.
- **Rehash a legacy bcrypt password to Argon2id at its next successful login;** until then, reject a password over 72 bytes with a clear message and never truncate it: bcrypt reads only the first 72 bytes.
- **Never store a password with a fast or unsalted hash.**
- **Use a CSPRNG for every token, secret and access-granting id;** never `Math.random` or `rand`.
- **Generate a fresh CSPRNG IV or nonce per message:** a reused or predictable one is its own defect (CWE-1204, CWE-323).
- **Encrypt with an authenticated (AEAD) mode.**
- **Encrypt sensitive data at rest:** default to the platform's or the store's encryption; add field-level encryption for credentials, card data, health data and government ids.
- **Require TLS:** sensitive data never travels in plaintext.
- **Never disable certificate verification** (`verify=False`, `InsecureSkipVerify`, a trust-all manager) outside one test run against a local or ephemeral environment, never a shared or production one.

## 5. Injection (OWASP A05)

- **Parameterize every query:** never build SQL, NoSQL, LDAP or XPath by concatenating or interpolating untrusted input (CWE-89).
- **Untrusted input never supplies a NoSQL query operator,** such as `$where` or another `$` operator.
- **Never hand untrusted input to a shell:** avoid dynamic command execution; where it is unavoidable, pass the command and its arguments as an array, never one shell string (CWE-78).
- **Encode output for its context** (HTML body or attribute, JavaScript, URL) at the sink, to stop XSS (CWE-79). `innerHTML`, `dangerouslySetInnerHTML`, disabled auto-escaping and `| raw` or `| safe` bypass it.
- **No `eval`, dynamic code or template built from request data** (CWE-94; server-side template injection, CWE-1336).
- **Disable external entities, DTD processing and entity expansion in every XML parser** (CWE-611, CWE-776): XXE reads files, reaches internal hosts and can run code, and a recursive entity (billion laughs) exhausts memory.

## 6. Insecure design (OWASP A06)

The PII lifecycle sits here: what is collected, erased and kept is a design decision. Resource limits and file uploads sit here too, by this standard's grouping: each is a limit the design must set.

- **Rate-limit security-sensitive flows** (login, OTP, password reset, payment, token issuance) and expensive or abusable endpoints.
- **Back off exponentially per account on repeated failed logins,** never by IP alone: an IP limit doesn't stop distributed credential stuffing, and a hard lockout lets an attacker lock users out.
- **Enforce business rules on the server** (limits, ownership, workflow state), never only on the client, so the design fails closed.
- **Cap request and body size, collection sizes and page size** (CWE-770): an unbounded allocation lets one request exhaust the service.
- **Cap a decompression's uncompressed size and file count before inflating** (decompression bomb, CWE-409).
- **Bound the input length before matching untrusted input with a regex, and use a pattern free of catastrophic backtracking** (ReDoS, CWE-1333); use a linear-time regex engine where a pattern can't be made safe.
- **Accept an upload only by an extension allow-list, and check that its content matches the type** (magic bytes, or re-writing an image); never trust the `Content-Type` header.
- **Cap every upload's size.**
- **Store an upload under a server-generated name** (such as a UUID); keep the user's file name only where the feature needs it, after the strict validation A01 sets for a user-supplied file name.
- **Store uploads outside the web root or on a separate host,** never executable, with least-privilege file permissions.
- **Serve an upload with a set `Content-Disposition` filename.**
- **Scan uploads with antivirus or content disarm and reconstruction (CDR)** where the platform offers it.
- **Collect only the PII the feature needs.**
- **Erase PII by hard delete or crypto-shredding:** a soft-delete is not erasure.
- **Anonymize irreversibly:** anonymized data can never be linked back to a person; pseudonymized data is still PII.
- **Give each data class a retention period,** enforced by a job.

## 7. Authentication failures (OWASP A07)

- **Issue a fresh session or token on login and on every privilege change.**
- **Expire every session, and invalidate it on logout.**
- **Never put a session token in a URL:** it leaks through logs, browser history and the `Referer` header (CWE-598).
- **Verify a JWT or signed token before trusting any claim:** check the signature, reject `alg: none` and algorithm confusion, and check `exp` and `nbf`, `aud`, the token type, and that the signing key belongs to the `iss`.
- **Require MFA at ASVS L2 and above:** ASVS leaves the level to each organisation's own risk analysis; this standard's policy sets it by what the app handles: L2 for an app with authentication, PII or payments, and L3 for a high-assurance app (finance, health, infrastructure). A project may set a higher level.
- **Require at least 15 characters for a password that is the only factor;** allow 8 only where the password is one factor of MFA (NIST SP 800-63B-4).
- **Allow passwords of at least 64 characters, of any character,** and set no composition rules (such as "one digit and one symbol"). The one exception: legacy bcrypt code rejects a password over 72 bytes until it is rehashed (A04).
- **Check every new or changed password, whole, against a blocklist of breached and common passwords.**
- **Never force periodic password rotation;** force a change only on evidence of compromise.
- **Allow paste and password managers, and never truncate a password.**

## 8. Software or data integrity failures (OWASP A08)

- **Never deserialize untrusted data into arbitrary types** (CWE-502): it leads to code execution. Deserialize only an allow-list of safe types. Examples: Java `ObjectInputStream`, Python `pickle` or `yaml.load`, PHP `unserialize`, .NET `BinaryFormatter`, Ruby `Marshal.load`.
- **Never merge untrusted keys into an object unfiltered:** a `__proto__`, `constructor` or `prototype` key changes every object that shares the prototype (prototype pollution, CWE-1321).
- **Verify every artifact, plugin and auto-update before loading it:** by signature where the publisher signs, otherwise by checksum.

## 9. Security logging and alerting failures (OWASP A09)

- Out of this standard: it sets no rule here.

## 10. Mishandling of exceptional conditions (OWASP A10)

- **Fail closed on error:** a security check that allows on an exception or a timeout is a vulnerability, such as an authorization lookup that throws and grants access.
- **Error responses leak nothing internal:** no stack trace, SQL, internal path or secret. Keep the detail internal and return a generic message.
