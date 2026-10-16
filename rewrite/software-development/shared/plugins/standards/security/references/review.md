# Security: review

Apply after `SKILL.md`'s rules when judging code by the security rules: judge the change by every rule there, then apply these. This file holds only how to judge a finding; it sets no category vocabulary or severity mapping.

- **A sink behind the framework's safe default is no finding** (`SKILL.md` Taint model).
- **Never judge the transitive CVE tree by eye:** it is a scanner's job (`SKILL.md` A03).
