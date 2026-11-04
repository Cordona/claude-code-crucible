# Shell script: review

## Correctness

- **Check for these shell correctness defects:**
  - an unchecked failure, `set -e`'s blind spots included;
  - a wrong exit code;
  - a TOCTOU race;
  - a feature the shebang's shell lacks.

## How to judge

- **Judge every feature against the shell the shebang names:** a bashism in a script that claims POSIX `sh` is a correctness defect.
- **Judge a sourced library by the caller's inherited `set` state,** not by a strict-mode line of its own (Strict mode and errors).
- **Cite the shellcheck code** (`SC2086`) for every lint finding.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.

## Severity

- **CRITICAL:**
  - exploitable injection: untrusted input run as a command or through `eval`, against the Injection section;
  - an untrusted value that reaches arithmetic without strict-integer validation (Injection).
- **HIGH:**
  - an unquoted expansion in a command (`SC2086`) over untrusted or path data;
  - missing strict mode for the shebang's shell, as the Strict mode and errors section sets, or relying on `set -e` where it doesn't fire;
  - a secret on argv, `export`ed, traced by `set -x`, or written before `umask 077`.
- **MEDIUM:**
  - a predictable temp file, or a missing cleanup `trap`;
  - a portability break the shebang's shell allows, from another platform's tools (a GNU-only flag in a cross-platform script), never a feature that shell lacks;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - a shellcheck style warning;
  - a suppression with no written reason.

**Overrides:**
- **A dev or throwaway script:** injection is still a finding at its level; only style is relaxed.
- **A script that runs as root:** hold its safety to a stricter bar.

**What moves a level:**
- A predictable temp file or a missing cleanup `trap` rises to HIGH when the script handles secrets or untrusted paths.
- A shellcheck style warning rises to MEDIUM when it hides a likely bug.
