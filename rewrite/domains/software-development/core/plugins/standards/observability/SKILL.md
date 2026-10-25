---
name: standard-observability
description: The observability rubric for production code in any language — pillars by codebase shape, log privacy and safety, security and audit events, log levels, structure, errors and cost, metrics and traces. Injected into the agent's first message when loaded. Writes nothing. Not for data protection beyond logs (standard-security), store correctness (standard-persistence), scaling cost (standard-performance), test code (standard-testing) or the logging library's API (its language or framework plugin).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Observability
---

# Standard: Observability

What observable code holds, in any language: operators can see what it is doing. Build instrumentation in as the code is written: never bolt it on after an incident. The developer builds to these rules, then follows `references/development.md`; a reviewer (once a review flow dispatches `code-reviewer`) judges by the same rules, then follows `references/review.md`. Both receive this file in their prompt, with their role's reference file right after it.

It is grounded in OpenTelemetry, W3C Trace Context, Google SRE (RED, USE and the Four Golden Signals), OWASP Top 10:2025, GDPR and 12-factor. A library named here (SLF4J, structlog, slog or zap, pino, OpenTelemetry) is an example only: map it to the stack in front of you.

## Scope

- **In:** code the developer writes or changes that runs in production (a service, job, handler or CLI), in any language. Also in:
  - **Alert routing:** where each alert the code raises goes.
- **Test code is out:** telemetry is a runtime concern.
- **Project conventions:** follow the project's logging and metrics conventions: its facade, field names, level policy, correlation mechanism, and metric and trace setup. Never introduce a second logging style. A convention never excuses a leak of secrets or PII, a missing security audit event or silent under-instrumentation: each is a defect even where the project does the same.

## Pillars by shape

Read every rule below through this section: which pillars a codebase needs follows from its shape and intent.

- **Instrument where it matters:** request paths, background jobs, integration boundaries, error handling and security-relevant events.
- **Under-instrumenting a service is a defect, and so is forcing a pillar onto a library or CLI.**
- **A pure function or trivial helper needs no telemetry:** adding it is noise.

| Shape | Logs | Metrics | Traces |
|---|---|---|---|
| Library or SDK (no process of its own) | Through the host's logger | OpenTelemetry API only; never bundle the SDK or force exporter config | API only; spans around network and significant I/O |
| CLI or batch (short-lived) | Structured; respect the verbosity flags | Rarely (only long-running or repeat jobs) | Only if it calls remote services |
| Single service or monolith | Yes | RED plus the Four Golden Signals | Recommended (intra-process spans) |
| Distributed or microservices | Yes, trace-correlated | RED per service | Required: W3C context across every hop |
| Async, queue or event-driven | Yes, trace-correlated | Queue depth / consumer lag | Required: context across the message boundary |
| Resource-bound component (DB, cache, pool, worker) | Yes | USE | Per shape |
| Pure logic (no I/O, no boundaries) | Minimal or none | No | No |

## 1. Log privacy and safety

- **Never log the deny-list:** passwords and credentials; tokens, API keys, `Authorization` and `Cookie` headers; private keys and certificates; connection strings; session ids, unless irreversibly hashed; payment and financial data. It is a security boundary, not a style preference.
- **Log allow-listed fields only; never dump a whole object, payload, body, entity or response:** a blanket dump smuggles in secrets and PII, and bloats volume.
- **Minimize PII:** prefer an opaque id or a pseudonym.
- **Mask, hash or pseudonymize special-category data.**
- **Keep the salt out of the log stream.**
- **PII in a log inherits GDPR retention (Art. 5(1)(e)) and the right to erasure (Art. 17):** never write PII to an indefinite or immutable store.
- **Neutralize log injection:** never write untrusted input to a log line without stripping or escaping CR/LF and other control characters; otherwise an attacker can forge or split log entries.
- **Logging must not crash the app.**

## 2. Security events and audit

- **Log every security-relevant event:** authentication success, failure, and lockout or backoff; authorization and access-control failures; privilege changes; input-validation failures; session lifecycle. A missing one on a security path is a defect.
- **Record who, what, when and outcome,** enough to reconstruct the event.
- **Never leak the sensitive payload in an event:** log the rule or an identifier, not the raw malicious payload.
- **Every audit record is kept apart from debug logs, tamper-evident, stamped with a synchronized, authoritative time, and retained for a bounded period.**
- **A compliance event (a change to legally required history included), or a business-required who-changed-what-when trail, is an audit record,** under the same rules as a security audit record.
- **Emit the events and metrics an alert needs:** repeated authentication failures, authorization failures on sensitive operations, and an audit-pipeline failure.
- **Route each alertable condition to its named owner or runbook;** its thresholds stay the platform's.

## 3. Log signal and levels

- **Log at meaningful points:** inbound and outbound boundaries, external calls, state transitions, significant business events, and errors with their context.
- **Missing logs around external calls and catch blocks is under-logging.**
- **No noise:** no logging in a loop on a hot path or per iteration, and no trivia; that is over-logging.
- **`ERROR` or `FATAL` only for a real failure or a loss of function:** never for an expected condition, such as a validation failure, a 404 or a retry that succeeded.
- **`WARN` for a recoverable anomaly.**
- **`INFO` for a significant business event.**
- **`DEBUG` for diagnostics.**
- **Never log everything at one level:** level filtering and alerting then can't tell a failure from diagnostics.
- **No `DEBUG` or `TRACE` detail at `INFO` or above on a production hot path.**
- **Log a slow query:** default to the store's own slow-query log where it has one; otherwise the data-access layer logs a query over the project's threshold at `WARN`, with its shape and duration, never its parameter values.

## 4. Log structure and correlation

- **Use structured key/value fields, not string interpolation:** `logger.info("order placed", orderId=id, userId=uid)`, not a formatted sentence.
- **Keep a consistent field schema:** stable key names and types.
- **Carry cross-cutting context in bound fields** (MDC, `With`, the span), with a correlation, request or trace id on every log line in a request's path, so one flow can be reconstructed.
- **Where traces exist, correlate logs by `trace_id` and `span_id`.**
- **Render through one config-driven format** (JSON in production, human-readable in development): never log the same event twice for two formats.

## 5. Errors and exceptions

- **Log or throw, never both:** `log(e); throw e;` reports the error again at every layer. Either handle and log it, or throw with context for a handler above to log.
- **Never swallow an exception silently:** a catch with neither a log nor a rethrow.
- **Log an exception once, at the layer that ends its handling,** never at one that also rethrows it.
- **Log it at the right level, with context, the identifiers needed to act, and the cause or stack.**
- **Scrub secrets and PII from exception messages and stack traces before they reach a log.**

## 6. Log cost and delivery

- **Guard or lazily evaluate an expensive log argument:** parameterized logging still evaluates its arguments, so wrap costly serialization in a level check or a lazy closure, and it costs nothing when the level is off.
- **Bound what you log:** truncate or summarize a large field or collection (a count and ids, not the contents), even when it passed the allow-list; size alone is a cost problem.
- **Use async, non-blocking appenders on a hot path.**
- **Write the event stream to stdout or stderr (12-factor):** the app never owns log-file paths, rotation or shipping; the platform routes it.
- **Sample verbose `INFO` and `DEBUG` to control cost, but never sample away an error or an audit record.**
- **Flush on shutdown:** drain and close the log, metric and trace providers before the process exits, above all in a CLI, a batch job or with an async exporter; buffered signals are silently dropped otherwise.

## 7. Logging facade

- **Log through a facade or the project's logging abstraction,** never a concrete framework wired through business code (SLF4J over Logback; slog's `Logger` over its `Handler`).
- **No competing logging frameworks.**
- **Get a named logger per module,** so an operator can filter a module's output and tune its level on its own.

## 8. Metrics

Only where the shape needs metrics (Pillars by shape).

- **RED, plus the Four Golden Signals, for request-driven work; USE for resources.**
- **Use the right instrument:** a Counter for a monotonic count, an UpDownCounter for a value that rises and falls, a Gauge for a point-in-time value, and a Histogram (distribution) for latency and size, never an average or a gauge, so p95 and p99 survive aggregation.
- **Record success and error latency separately.**
- **Bound cardinality: no high-cardinality dimension,** such as a user or request id, a raw URL or an email as a label. It is the top metrics defect.
- **Give each metric a consistent, namespaced semantic-convention name** (`orders.placed.count`).
- **Give each metric an explicit base unit** (seconds, not milliseconds; bytes): a wrong unit silently breaks dashboards and cross-service aggregation.
- **Remove a dead metric:** one on no dashboard or alert.

## 9. Traces

Only where the shape needs traces (Pillars by shape).

- **Propagate W3C trace context** (`traceparent`, `tracestate`) across every service hop and every async or message boundary, with standard propagators, never homegrown ids.
- **Keep span names low-cardinality:** `GET /users/{id}`, never a raw id.
- **On failure, set the span status to Error and record the exception.**
- **Set the correct span kind:** Client, Server, Producer or Consumer.
- **One span per meaningful unit of work:** no span per loop iteration, and no childless mega-span.
- **Reuse semantic-convention attribute names.**
- **Span the meaningful boundaries** (external calls, DB queries, significant work), not every trivial call.
- **All telemetry carries `service.name`, `service.version` and `deployment.environment`:** without them, signals can't be attributed or correlated across services.
