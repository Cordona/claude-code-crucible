# Shell script: review

Apply with `SKILL.md`'s rules when judging a shell script: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness for shell:** this language plugin, with any framework plugins loaded beside it, judges whether the code does what it is meant to. Check for:
  - an unchecked failure, `set -e`'s blind spots included;
  - a wrong exit code;
  - a TOCTOU race;
  - a feature the shebang's shell lacks;
  - boundary and error paths that are incomplete;
  - behaviour that breaks its intended contract.

## How to judge

- **Judge every feature against the shell the shebang names:** a bashism in a script that claims POSIX `sh` is a correctness defect, graded by Correctness above.
- **Judge a sourced library by the caller's inherited `set` state,** not by a strict-mode line of its own (`SKILL.md` Strict mode and errors).
- **Cite the shellcheck code** (`SC2086`) for every lint finding.
- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.
- **Verify a shell or tool API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a shell defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - exploitable injection: untrusted input run as a command or through `eval`, against `SKILL.md`'s Injection section;
  - an untrusted value that reaches arithmetic without strict-integer validation (`SKILL.md` Injection).
- **HIGH:**
  - an unquoted expansion in a command (`SC2086`) over untrusted or path data;
  - missing strict mode for the shebang's shell, as `SKILL.md`'s Strict mode section sets, or relying on `set -e` where it doesn't fire;
  - a correctness defect from Correctness above;
  - a secret on argv, `export`ed, traced by `set -x`, or written before `umask 077`.
- **MEDIUM:**
  - a predictable temp file, or a missing cleanup `trap`;
  - a portability break the shebang's shell allows, from another platform's tools (a GNU-only flag in a cross-platform script), never a feature that shell lacks;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - a shellcheck style warning;
  - a suppression with no written reason.

**Overrides:**
- **Test code:** a build diff that changes test code, a test module inside a source file included, is HIGH, as `code-reviewer` sets; no rule here grades test code lower.
- **A dev or throwaway script:** injection is still a finding at its level; only style is relaxed.
- **A script that runs as root:** hold its safety to a stricter bar.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- Injection and remote code execution drop to HIGH when exploiting them is harder or reaches less.
- A predictable temp file or a missing cleanup `trap` rises to HIGH when the script handles secrets or untrusted paths.
- A shellcheck style warning rises to MEDIUM when it hides a likely bug.
