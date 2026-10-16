# Persistence: review

Apply after `SKILL.md`'s rules when judging code by the persistence rules: judge the change by every rule there, then apply these. This file holds only how to judge a finding; it sets no category vocabulary or severity mapping.

- **Flag offset paging only on large or changing data:** where `SKILL.md` §4 "Page stably" keeps offset correct, it is no finding.
- **Flag a stale read only past the task's consistency need:** a store read that misses a just-committed write (eventual consistency, replica lag), or an application or read-model cache serving a value older than the need allows. Staleness the need allows is no finding.
