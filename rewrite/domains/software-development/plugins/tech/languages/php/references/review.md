# PHP: review

Apply with `SKILL.md`'s rules when judging PHP: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness for PHP:** this language plugin, with any framework plugins loaded beside it, judges whether the code does what it is meant to. Check for:
  - a loose `==` or `!=` on a logic- or security-sensitive comparison, a non-strict `in_array` or `array_search`, or a `switch` where a loose match is wrong;
  - a float compared with `==` or `===`;
  - a `json_decode` with no `JSON_THROW_ON_ERROR` or null check, or an enum `from()` on untrusted input;
  - an undefined array key or property read, a `?->` that masks a real null, or a `??` that hides a required value;
  - `switch` fall-through on a missing `break`, or non-exhaustive enum handling;
  - integer overflow into a float; an overflow with a security consequence is graded here, as correctness, not only arithmetic;
  - an empty or over-broad `catch`, or a swallowed error;
  - boundary and error paths that are incomplete;
  - behaviour that breaks its intended contract.

## How to judge

- **No manual formatting finding:** the developer's format step covers it.
- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.
- **Verify a PHP or library API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a PHP defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - exploitable injection: SQL built from untrusted input, against `SKILL.md`'s Queries mechanism;
  - remote code execution: `unserialize()` on untrusted input, against `SKILL.md`'s Deserialization mechanism;
  - remote code execution: `eval()` or a dynamic `include` on untrusted input, against `SKILL.md`'s Code execution mechanism.
- **HIGH:**
  - a correctness defect from Correctness above;
  - reflected or stored XSS: a value written into HTML unescaped, against `SKILL.md`'s Output mechanism.
- **MEDIUM:**
  - a new file without `declare(strict_types=1)`;
  - an unpinned dependency or another supply-chain gap, against `SKILL.md`'s Supply chain mechanism;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - a missing type declaration, or `mixed` where a real type fits;
  - micro-performance;
  - a suppression with no written reason.

**Overrides:**
- **Test code:** a build diff that changes test code, a test module inside a source file included, is HIGH, as `code-reviewer` sets; no rule here grades test code lower.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- Injection and remote code execution drop to HIGH when exploiting them is harder or reaches less.
- A fail-open check, client-side data exposure and XSS drop to MEDIUM when exploiting them is harder or reaches less.
- Micro-performance rises above LOW only on a hot path.
