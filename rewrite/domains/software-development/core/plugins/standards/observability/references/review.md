# Observability: review

Apply after `SKILL.md`'s rules when judging code by the observability rules: judge the change by every rule there, then apply these. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

- **Name the codebase's shape before flagging a missing pillar:** a pillar its row in `SKILL.md` Pillars by shape doesn't need is no finding; one forced onto a library or CLI is.
- **A pure function or trivial helper with no telemetry is no finding** (`SKILL.md` Pillars by shape).
- **Instrumentation the framework or its config provides is no finding,** neither as missing nor as duplicate.
- **A project that does observability its own way, consistently:** raise the tension once; don't flag every instance.

## Severity

Where an observability defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - none for this lens.
- **HIGH:**
  - secrets, credentials or personal data leaked into logs;
  - a required security or audit event missing on a security path.
- **MEDIUM:**
  - logging that can crash the app; unneutralised log injection;
  - high-cardinality metric dimensions;
  - missing trace-context propagation on a distributed or async service (an operability gap: it raises the cost of the next debugging session and ships no defect);
  - log-and-throw duplication, or a silently swallowed error;
  - a wrong log level that causes alert fatigue (ERROR for an expected case);
  - under-logging a critical boundary or error path;
  - unstructured logs in production, an inconsistent field schema, or a missing correlation id;
  - missing RED or USE metrics on a service or resource that needs them.
- **LOW:**
  - span quality (names, kind, status, granularity); unguarded expensive log arguments; huge payloads;
  - over-logging noise; in-app log file or rotation management; bypassing the logging facade; a deviation from the project's observability conventions;
  - pillars or instrumentation forced onto a library or CLI that doesn't need them;
  - double-logging for two formats; dead metrics.

**Overrides:**
- none for this lens.

**What moves a level:**
- Logging that can crash the app, log injection and high-cardinality dimensions rise to HIGH when the harm reaches users or the service.
- Span quality, payload, noise, file-management, facade, convention and forced-pillar issues rise to MEDIUM when the cost is real for this codebase.
