# Boundary map: which plugin owns a shared concern

The one concern-to-owner table for the plugins. Read it at SKILL.md's step 5, when two plugins' descriptions both match one concern of a task.

- **The concern goes to its owner:** load the owner for it.
- **A non-owner is still loaded for a concern of its own** the task also touches: the half a row leaves it, or a concern no row lists. A shared concern alone never pulls it in.
- **A standard or procedure plugin left out by a row** goes into `--skip`, its reason *(<concern>: owned by `<owner>`)*. A language or framework plugin is never left out by a row: it keeps its own form of the concern.
- **The language plugin** is that of the language the code is in, such as `language-shell`; **a framework plugin**, that of a framework the code uses.

| Concern | Owner | What the others keep |
|---|---|---|
| Secrets: storing, fetching and handling one, and never passing one on a command line (`ps` shows it) | `standard-security` | `language-shell`: only the shell's own forms, such as `VAR=… cmd` and `umask 077`. `standard-persistence`: nothing |
| A secret, PII or untrusted input in a log line | `standard-observability` | `standard-security`: nothing |
| Security events, audit records and their alerts (OWASP A09) | `standard-observability` | `standard-security`: nothing |
| Alert routing: where an alert the code raises goes | `standard-observability` | every other standard: nothing |
| Data protection beyond logs: encryption at rest, PII minimization, erasure and retention policy | `standard-security` | `standard-persistence`: the store's mechanism (a hard delete, a TTL, the store's encryption). `standard-observability`: nothing |
| A soft-delete is not erasure | `standard-security` | `standard-persistence`: nothing |
| Legally required history: storing it, append-only | `standard-persistence` | `standard-observability`: nothing |
| Legally required history: emitting the audit event about it | `standard-observability` | `standard-persistence`: nothing |
| History the domain rebuilds state from | `standard-persistence` | `standard-observability`: nothing |
| Slow-query logging, query metrics, data-layer tracing, an audit trail kept for its own sake | `standard-observability` | `standard-persistence`: nothing |
| Query injection and unsafe query construction | `standard-security` | `standard-persistence`: nothing |
| Untrusted input reaching a shell or `eval` | `standard-security` | `language-shell`: the shell's own forms (`eval`, `bash -c`, `sh -c`, arithmetic on untrusted input) |
| Id enumeration (IDOR) and an id that grants access | `standard-security` | `standard-persistence`: the id's fit to the store's partition and index model |
| A durable store's correctness, its key shape included | `standard-persistence` | `standard-security`, `standard-performance`: nothing |
| Index design for a store query | `standard-persistence` | every other standard: nothing |
| Store choice: which durable store a need goes to | `standard-persistence` | every other standard: nothing |
| Aggregate and transaction-boundary sizing | `standard-persistence` | every other standard: nothing |
| Cache coherence: an application or read-model cache kept in step with its store | `standard-persistence` | `standard-performance`: whether to cache a result fetched again across calls |
| A migration's consumer axis: who outside the change breaks | `standard-persistence` | every other standard: nothing |
| Backup, restore and disaster recovery | `standard-persistence` | every other standard: nothing |
| A cap on body, collection and page size | `standard-security`: the cap on what a caller controls | `standard-performance`: its cost at scale. `standard-persistence`: its correctness |
| N+1, bounded reads, offset paging, over-wide reads | `standard-performance`: their cost at scale | `standard-persistence`: their correctness (stable paging, a result set held within memory) |
| Blocking I/O on a latency-sensitive path | `standard-performance` | `standard-observability`: the logging side (async, non-blocking appenders) |
| How code scales with its input | `standard-performance` | `standard-clean-code`: nothing |
| Test-only rules | `standard-testing` | every other standard: nothing (`standard-observability` covers no test code) |
| Test and scenario names | `standard-testing` | `standard-self-documenting-code`: nothing |
| Every other name, comment and docstring, test code included | `standard-self-documenting-code` | `standard-clean-code`, `standard-testing`: nothing |
| Code structure: responsibility, duplication, coupling, function size, dead code, file layout | `standard-clean-code` | `standard-self-documenting-code`: nothing |
| Test-code structure | `standard-clean-code` | `standard-testing`: its tie-breakers where a test pulls against clean code |
| Reading a tracker link the context holds (a GitHub, GitLab or Jira issue), read-only | `procedure-read-trackers` | every other plugin: nothing. Any other link, and how the whole context is read, weighed and reported, is no plugin's: the first message's `# Handling your context` sets it |
| A language's own form of a rule: language mechanics, memory safety, micro-performance, doc-comment syntax, layout idioms | the language plugin | each standard: the language-agnostic rule |
| A framework's own form of a rule: its API and idioms, ORM mechanics, the logging library's API | the framework plugin of that framework, when one is loaded; otherwise the language plugin | the language plugin: the language's own mechanics. Each standard: the language-agnostic rule |
