# Security: review

- **No finding without a concrete attack scenario:** name who sends what, and what they gain.
- **Weight access control and injection highest,** and lean toward recall on a genuine CRITICAL.

## Severity

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
