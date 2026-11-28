---
name: framework-nextjs-review
description: "Next.js rules for a review job agent, preloaded through its agent file. Not for main."
user-invocable: false
metadata:
  label: Next.js, review
---

# Next.js: review

## How to judge

- **Verify a Next.js API or version-specific behaviour against its current docs**, caching above all, before filing a finding that turns on it, never from memory alone.

## Severity

- **CRITICAL:**
  - a transaction split across Server Action or route handler round-trips: a non-atomic multi-write with no compensation.
- **HIGH:**
  - a Server Action or route handler that doesn't authorize its caller, or leaves it to middleware alone;
  - identity, role or tenant taken from caller-supplied input.
- **MEDIUM:**
  - a mutation that leaves cached data stale where the next read must see it;
  - hand-rolled route-level code splitting;
  - a heavy client component loaded eagerly.

