# Observability: development

Apply after `SKILL.md`'s rules, before writing code.

## Reporting

`standard-code-development-report` sets each item's shape.

- **The codebase's shape and the pillars it got** -> the report's `decisions`, because the reviewer judges the pillar choice by the shape (`SKILL.md` Pillars by shape).
- **The owner or runbook you assumed for an alertable condition, or that none is named (say which)** -> the report's `open` (`assumption`), because only the human can confirm it.

## Self-check before reporting

1. The codebase's shape was named, and it got the pillars its row in `SKILL.md` Pillars by shape gives. No pillar is missing from a service, and none is forced onto a library, CLI or pure function. Instrumentation sits at request paths, jobs, integration boundaries, error handling and security-relevant events.
2. No deny-listed field, whole object or unscrubbed exception reaches a log. PII is minimized, special-category data masked, hashed or pseudonymized, and the salt kept out. No PII goes to an indefinite or immutable store. Untrusted input is neutralized, and logging can't crash the app.
3. Every security-relevant event is logged with who, what, when and outcome, and no sensitive payload. Every audit record, security or domain, is kept apart, tamper-evident, time-stamped and retention-bounded. Each alertable condition emits its signal and names its owner or runbook.
4. Logs sit at meaningful points, at the right level, with no hot-loop noise. Slow queries are logged by shape and duration, never parameter values. Fields are structured, with a stable schema and a correlation, request or trace id, in one config-driven rendering.
5. Each exception is logged once or thrown, never both and never swallowed. It carries context, identifiers and cause, scrubbed of secrets and PII.
6. Costly log arguments are guarded, large fields bounded, and appenders async on a hot path. Output goes to stdout or stderr, sampling spares errors and audit records, and providers flush on shutdown. Logging goes through a facade, one framework, with a named logger per module.
7. Metrics use RED or USE, the right instrument, bounded cardinality, a namespaced name and a base unit, with no dead metric. Traces propagate W3C context, with well-formed spans at meaningful boundaries. All telemetry carries the service identity. The project's conventions were followed, and none excused a leak, a missing audit event or under-instrumentation.
8. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
