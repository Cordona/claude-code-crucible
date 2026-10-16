# Self-documenting code: review

Apply after `SKILL.md`'s rules when judging comments, docstrings and names: judge the change by every rule there, then apply these. This file holds only how to judge a finding; it sets no category vocabulary or severity mapping.

- **Flag a REDUNDANT comment only with its concrete rewrite:** the rename, extraction, named constant or plain deletion that removes it. If you can't write one, don't flag it: the comment is carrying a why the code can't.
- **The proportionality bars need no rewrite:** a volume, extreme-instance or placement finding is judged by its own bar, and the rewrite rule above doesn't veto it.
- **Never flag a FUNCTIONAL comment.**
- **Never flag a PUBLIC-API DOC comment** unless it only restates the signature.
- **Flag a missing docstring only on a public surface;** never ask for one on an internal or private member.
- **When the change doesn't show whether a surface is public, treat it as internal,** and say so in the finding.
- **Check the placement bar only when the commit message or the PR or MR description is in front of you:** its absence is no evidence of duplication.
- **A docstring that follows a documented, official language convention is no finding,** once you have confirmed the convention is real and official, not the author's habit.
- **If you can't name what a comment, docstring or name costs the reader here, don't flag it.**
