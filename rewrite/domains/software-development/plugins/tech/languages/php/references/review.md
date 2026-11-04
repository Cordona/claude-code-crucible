# PHP: review

## Correctness

- **Check for these PHP correctness defects:**
  - a loose `==` or `!=` on a logic- or security-sensitive comparison, a non-strict `in_array` or `array_search`, or a `switch` where a loose match is wrong;
  - a float compared with `==` or `===`;
  - a `json_decode` with no `JSON_THROW_ON_ERROR` or null check, or an enum `from()` on untrusted input;
  - an undefined array key or property read, a `?->` that masks a real null, or a `??` that hides a required value;
  - `switch` fall-through on a missing `break`, or non-exhaustive enum handling;
  - integer overflow into a float, including an overflow with a security consequence;
  - an empty or over-broad `catch`, or a swallowed error.

## How to judge

- **No manual formatting finding:** the developer's format step covers it.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.

## Severity

- **CRITICAL:**
  - exploitable injection: SQL built from untrusted input, against PHP's Queries mechanism;
  - remote code execution: `unserialize()` on untrusted input, against the Deserialization mechanism;
  - remote code execution: `eval()` or a dynamic `include` on untrusted input, against the Code execution mechanism.
- **HIGH:**
  - reflected or stored XSS: a value written into HTML unescaped, against the Output mechanism.
- **MEDIUM:**
  - a new file without `declare(strict_types=1)`;
  - an unpinned dependency or another supply-chain gap, against the Supply chain mechanism;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - a missing type declaration, or `mixed` where a real type fits;
  - micro-performance;
  - a suppression with no written reason.

**What moves a level:**
- Micro-performance rises above LOW only on a hot path.
