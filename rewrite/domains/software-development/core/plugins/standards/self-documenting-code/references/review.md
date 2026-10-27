# Self-documenting code: review

Apply after `SKILL.md`'s rules when judging comments, docstrings and names: judge the change by every rule there, then apply these. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

- **Flag a REDUNDANT comment only with its concrete rewrite:** the rename, extraction, named constant or plain deletion that removes it. If you can't write one, don't flag it: the comment is carrying a why the code can't.
- **The proportionality bars need no rewrite:** a volume, extreme-instance or placement finding is judged by its own bar, and the rewrite rule above doesn't veto it.
- **Never flag a FUNCTIONAL comment.**
- **Never flag a PUBLIC-API DOC comment** unless it only restates the signature.
- **Flag a missing docstring only on a public surface;** never ask for one on an internal or private member.
- **When the change doesn't show whether a surface is public, treat it as internal,** and say so in the finding.
- **Check the placement bar only when the brief gives the commit message's or the PR or MR description's full absolute path:** its absence is no evidence of duplication.
- **A docstring that follows a documented, official language convention is no finding,** once you have confirmed the convention is real and official, not the author's habit.
- **If you can't name what a comment, docstring or name costs the reader here, don't flag it.**
- **No comment surface, no finding:** pure config, or one-line trivia with no author-written prose, gets none; say so, and never manufacture one.

## Severity

Where a self-documenting-code defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - none for this lens.
- **HIGH:**
  - none for this lens.
- **MEDIUM:**
  - systematic over-commenting: a pattern recurring across two or more units;
  - cross-artifact duplication, even a single instance.
- **LOW:**
  - an extreme comment-to-code ratio in a single instance;
  - a single redundant comment or docstring; commented-out code;
  - a missing required doc comment on a public or consumed surface;
  - a name that fails to carry the meaning that would otherwise force a comment;
  - a magic number or literal with no named constant.

**Overrides:**
- none for this lens.

**What moves a level:**
- An extreme single-instance ratio rises to MEDIUM when it is pervasive.
- A missing doc comment rises to MEDIUM when the surface is not obvious without it (an error-prone or unsafe-equivalent contract).
