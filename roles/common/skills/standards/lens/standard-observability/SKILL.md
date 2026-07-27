---
name: standard-observability
description: The single definition of observable code — the shared rubric that developers BUILD to and the observability lens REVIEWS against. Applies whenever code runs in production (services, jobs, handlers, CLIs) in any language. Grounded in OpenTelemetry, W3C Trace Context, Google SRE, OWASP, GDPR, and 12-factor. Defines instrument-by-shape (the pillar applicability by codebase shape), structured logging with correlation and levels, no sensitive data / no PII / log-injection neutralization, error context logged once, metrics (RED/USE, instruments, cardinality, units), trace-context propagation and span quality, resource attributes, auditability, telemetry flush, and the logging facade. This is WHAT good looks like; it does not define builder workflow (build-core), the reviewer's pillar-gate procedure / convention-profiling / severity / vocabulary (the lens), or broad data protection beyond logs (security).
---

# Standard: Observability

The **one** definition of observable code — instrumented so operators can see what it's doing, built in as you write, not bolted on after an incident. Developers build to it; the `lens-observability-reviewer` judges against it. Both bind this single skill, so there is no daylight between how we build and how we review.

Grounded in **OpenTelemetry**, **W3C Trace Context**, **Google SRE** (RED/USE, Four Golden Signals), **OWASP**, **GDPR**, and **12-factor**. Framework-agnostic — names (SLF4J, structlog, slog/zap, pino, OTel) are illustrative; map them to the target's stack.

This skill defines **WHAT good looks like**. It does NOT contain: the builder's workflow (`build-core`); the reviewer's machinery (the pillar-applicability *gate procedure*, convention-profiling *method*, severity, `category` vocabulary, false-positive guards — those live in the lens); or broad data protection beyond logs (security).

## Instrument by shape (scope it right)

Instrument **where it matters** — request paths, background jobs, integration boundaries, error handling, and security-relevant events. **Under-instrumenting a service is a defect; forcing pillars onto a library/CLI is ALSO a defect.** A pure function or trivial helper needs no telemetry — don't add noise. Which pillars a codebase needs follows from its shape + intent:

| Codebase shape | Logs | Metrics | Traces |
|---|---|---|---|
| **Library / SDK** (no process of its own) | via the host's logger | OTel **API-only**, never bundle the SDK or force exporter config | API-only; spans around network/significant I/O |
| **CLI / batch** (short-lived) | structured; respect verbosity flags | rarely (only long-running/repeat jobs) | only if it calls remote services |
| **Single service / monolith** | ✅ | RED + Four Golden Signals | recommended (intra-process spans) |
| **Distributed / microservices** | ✅ trace-correlated | RED per service | **required** — W3C context across every hop |
| **Async / queue / event-driven** | ✅ trace-correlated | queue depth / consumer lag | **required** — context across the message boundary |
| **Resource-bound component** (DB/cache/pool/worker) | ✅ | **USE** (Utilization/Saturation/Errors) | per shape |
| **Pure logic** (no I/O, no boundaries) | minimal/none | no | no |

## Logs — Privacy & Safety

- **Never log the deny-list:** passwords/credentials, tokens/API keys/`Authorization`/`Cookie` headers, private keys/certs, connection strings, session ids (unless irreversibly hashed), payment/financial data. This is a security boundary, not a style preference.
- **Allow-list fields — never dump a whole object/payload/body/entity/response.** A blanket dump smuggles in secrets + PII and bloats volume.
- **PII:** minimize (prefer an opaque id/pseudonym); mask/hash/pseudonymize special-category data; keep the salt out of the log stream. PII inherits **GDPR** retention (Art. 5(1)(e)) + right-to-erasure (Art. 17) — do not write PII to indefinite/immutable stores.
- **Neutralize log injection:** never write untrusted input to a log line without stripping/escaping newlines (CR/LF) and control characters — otherwise an attacker can forge or split log entries.
- Logging **must not crash the app**, and must not leak secrets via raw exception/stack traces.

## Logs — Signal & Levels

- **Log at meaningful points:** boundaries (inbound/outbound), external calls, state transitions, significant business events, and errors with context. Missing logs around external calls and catch blocks is under-logging.
- **No noise:** no hot-loop / per-iteration logging, no trivia (over-logging).
- **Levels:** `ERROR`/`FATAL` only for real failures / loss of function — NOT expected conditions (validation, 404, successful retry) · `WARN` recoverable anomalies · `INFO` significant business events · `DEBUG` diagnostics. No everything-at-one-level; no DEBUG/TRACE detail at INFO+ on prod hot paths.

## Logs — Structure & Correlation

- **Structured key/value fields**, not string interpolation: `logger.info("order placed", orderId=id, userId=uid)`, not a formatted sentence. Keep a **consistent field schema** (stable key names/types).
- Carry cross-cutting context via **bound/contextual fields** (MDC / `With` / span), including a **correlation/request/trace id** on every log line in a request's path so a single flow can be reconstructed; where traces exist, correlate logs via `trace_id`/`span_id`.
- **One config-driven rendering** (JSON in prod, human in dev) — never double-log the same event for two formats.

## Logs — Error & Exception

- **Log-or-throw, never both** — `log(e); throw e;` double-reports up the layers. Either handle-and-log, or throw with context for a handler above to log. No silent swallow (catch with neither log nor rethrow).
- Log an exception **once**, at the right level, with **context + the identifiers needed to act + the cause/stack**, then propagate or handle.
- **Scrub** secrets/PII from exception messages and stack traces before they reach logs.

## Logs — Performance & Cost

- **Guard/lazy-evaluate expensive log arguments** — parameterized logging still evaluates its arguments; wrap costly serialization in a level check or lazy closure so it costs nothing when the level is disabled.
- No huge payloads / whole collections — truncate/summarize/log counts + ids.
- Async/non-blocking appenders on hot paths.
- **12-factor:** write the event stream to **stdout/stderr**; the app must not own log-file paths, rotation, or shipping — let the platform route it.
- **Sampling** controls cost — but **never sample away errors or audit events**; sample verbose INFO/DEBUG.
- **Flush on shutdown** — drain/close the log, metric, and trace providers before the process exits (especially CLIs, batch jobs, async exporters); buffered signals are silently dropped otherwise.

## Logs — Facade

Log via a **facade / the project's logging abstraction**, not a concrete framework wired through business code (SLF4J↔Logback; slog `Logger`/`Handler`). No competing frameworks; obtain a **named per-module logger**.

## Metrics *(where the shape requires them)*

- **RED** for request-driven work (Rate, Errors, Duration) + Four Golden Signals; **USE** for resources (Utilization, Saturation, Errors of pools/queues/caches).
- **Correct instrument:** Counter (monotonic), UpDownCounter (rises/falls), Gauge (point-in-time), **Histogram/distribution** for latency/size (not an average or gauge, so p95/p99 survive aggregation); separate success vs error latency.
- **Bound cardinality — NO high-cardinality dimensions** (user/request ids, raw URLs, emails as labels): the top metrics defect.
- **Naming & units:** a consistent namespaced, semantic-convention name (`orders.placed.count`) and an explicit **base unit** (seconds not milliseconds, bytes) — wrong units silently break dashboards and cross-service aggregation.
- Remove **dead metrics** (not on any dashboard/alert).

## Traces / Spans *(where the shape requires them)*

- **Propagate W3C trace context** (`traceparent`/`tracestate`) across every service hop AND async/message boundary; use standard propagators, not homegrown ids.
- **Span quality:** low-cardinality span names (`GET /users/{id}`, never raw ids); set **span status = Error** + record the exception on failure; correct **span kind** (Client/Server/Producer/Consumer); one span per meaningful unit of work (no span-per-loop-iteration, no childless mega-span); reuse **semantic-convention** attribute names. Span the meaningful boundaries (external calls, DB queries, significant work) — not every trivial call.
- **Resource / service identity:** all telemetry carries `service.name`, `service.version`, `deployment.environment` — without them signals can't be attributed or correlated across services.

## Auditability

- **Security-relevant events must be present:** authentication (success/failure/lockout), authorization/access-control failures, privilege changes, input-validation failures, session lifecycle. Absence on a security path is a defect. Record **who, what, when, outcome** — enough to reconstruct the event, without leaking the sensitive payload (log a rule/identifier, not the raw malicious payload).
- **Audit records:** separated from debug logs, tamper-evident, with synchronized/authoritative timestamps and bounded retention.

## Consistency

Use the **project's existing logging/metrics facade and conventions** — the same field names, level policy, correlation mechanism, and metric/trace setup as its neighbors. Don't introduce a second logging style.

---
*Standard Version: 1.0 — the shared observability rubric, grounded in OTel / W3C Trace Context / Google SRE / OWASP / GDPR / 12-factor. Built to by developers (via build-core); reviewed against by lens-observability-reviewer.*
