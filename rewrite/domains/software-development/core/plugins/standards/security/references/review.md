# Security: review

Apply after `SKILL.md`'s rules when judging code by the security rules: judge the change by every rule there, then apply these. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

- **A sink behind the framework's safe default is no finding** (`SKILL.md` Taint model).
- **Never judge the transitive CVE tree by eye:** it is a scanner's job (`SKILL.md` A03).
- **No attack surface, no finding:** a change with no untrusted input, sink, secret or privilege gets none; say so, and never manufacture one.
- **No finding without a concrete attack scenario:** name who sends what, and what they gain.
- **Weight access control and injection highest,** and lean toward recall on a genuine CRITICAL.

## Severity

Where a security defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - exploitable injection or remote code execution (SQL, OS command, unsafe deserialization).
- **HIGH:**
  - broken access control: a missing authorization check, an insecure direct object reference, an auth bypass;
  - a hardcoded secret;
  - SSRF that can reach internal hosts or cloud metadata;
  - passwords stored with weak hashing;
  - TLS verification turned off;
  - a security check that fails open;
  - sensitive data exposed to the client;
  - reflected or stored XSS.
- **MEDIUM:**
  - missing security headers, a permissive CORS policy, or another misconfiguration;
  - unpinned dependencies or another supply-chain gap;
  - missing rate limiting;
  - missing CSRF protection on a non-critical flow.
- **LOW:**
  - defence-in-depth or lower-impact hardening.

**Overrides:**
- A hardcoded real secret is a finding wherever it lives, test and fixture code included.
- Never lower a real, exploitable vulnerability because the project does it the same way everywhere.

**What moves a level:**
- Injection and remote code execution drop to HIGH when exploiting them is harder or reaches less.
- A fail-open check, client-side data exposure and XSS drop to MEDIUM when exploiting them is harder or reaches less.
