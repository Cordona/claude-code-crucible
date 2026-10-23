# Shell: review

Apply after `SKILL.md`'s rules when judging a shell script: judge the change by every rule there, then apply these. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

- **This lens owns correctness for shell:** does the script do what it is meant to, on every path, exit code and boundary; other lenses hand their correctness concerns to it.
- **Judge every feature against the shell the shebang names:** a bashism in a script that claims POSIX `sh` is a finding.
- **Judge a sourced library by the caller's inherited `set` state,** not by a strict-mode line of its own (`SKILL.md` Strict mode and errors).
- **Cite the shellcheck code** (`SC2086`) for every lint finding; a `# shellcheck disable` with no stated reason is a finding.

## Severity

Where a shell defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - command injection, or `eval` of untrusted input.
- **HIGH:**
  - an unquoted expansion in a command (`SC2086`) over untrusted or path data;
  - missing `set -euo pipefail`, or relying on `set -e` where it doesn't fire;
  - a correctness defect: an unchecked failure, a wrong exit code, a TOCTOU race.
- **MEDIUM:**
  - a predictable temp file, or a missing cleanup `trap`;
  - a portability break (a GNU-only flag in a cross-platform script).
- **LOW:**
  - a shellcheck style warning.

**Overrides:**
- A dev or throwaway script: injection is still a finding at its level; only style is relaxed.
- A script that runs as root: hold its safety to a stricter bar.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- A predictable temp file or a missing cleanup `trap` rises to HIGH when the script handles secrets or untrusted paths.
- A shellcheck style warning rises to MEDIUM when it hides a likely bug.
