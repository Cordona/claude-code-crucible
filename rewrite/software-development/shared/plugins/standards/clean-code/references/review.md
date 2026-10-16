# Clean code: review

Apply after `SKILL.md`'s rules when judging code by the clean-code rules: judge the change by every rule there, then apply these. This file holds only how to judge a finding; it sets no category vocabulary or severity mapping.

- **Flag only a concrete harm:** name what the structure costs in this code, such as one change that must now be made in two places, a flow the reader must follow backward, or dead code that misleads. If no harm can be named, don't flag it.
- **Clarity is the goal, not compliance:** a principle followed for its own sake gains nothing, and a principle not applied is no finding by itself.
- **Never flag an order the language forces:** a declaration placed before its use because of a temporal dead zone or a forward-reference rule follows `SKILL.md`'s file-layout exception.
