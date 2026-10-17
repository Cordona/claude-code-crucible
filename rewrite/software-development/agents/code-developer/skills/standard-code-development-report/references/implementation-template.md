# Implementation Report: template

## Contents

- Rules for rendering
- The layout
- Fix rounds
- Example: a report
- Example: a fix round

The layout of the Implementation Report a developer sends back, and of its finding lines. What each field holds, and the rules behind the report, are SKILL.md's. The line order is fixed; the rendering is the default.

## Rules for rendering

- **The line order is fixed; the rendering is the default:** keep every line in the order below; the heading, bold labels and bullets shown are the default rendering, not a fixed form.
- **The code blocks below only show the lines:** the report itself is live Markdown, never fenced (SKILL.md's Style).
- **A blank line after every label and every line of text:** Markdown joins lines with no blank line between them, so a label would run into its text, and finding lines into each other.
- **Bold field labels.**
- **A field that holds a list gives one bullet per item.**
- **Verification is one line** of gates, each with its result, separated by ` · `.
- **A field with nothing to list says `none`** on its label's line (`**Open blockers:** none`).

## The layout

```
## Implementation Report

**Technology:** <language or framework, with its version>

**Files created/modified**

- `<repo-relative path>` — <purpose>

**What was implemented**

<2–3 sentences: what and why>

**Key decisions**

- <choice>: <one-line rationale>

**Verification**

- <gate> <result> · <gate> <result> · …

**Open blockers**

- <each blocker>

**Open points**

- <each point>

**Handoff to reviewer**

- <a focus, a trade-off, or a conflict to judge>

**<Extra field, when a dispatch sets one>**

- <its content>
```

## Fix rounds

A fix round needs the reviewer (once `code-reviewer` exists). The finding lines come first, one per finding the brief hands you; then the heading and every field, as The layout sets.

```
<reviewer ID> (<severity>) — fixed|not fixed (proposal)|blocked: <what changed, or why not>

<the next finding line>

## Implementation Report

<every field, as The layout sets; unchanged where nothing is new since the last report, never in Verification>
```

The finding line, exact: `<reviewer ID> (<severity>) — fixed|not fixed (proposal)|blocked: <what changed, or why not>`.

## Example: a report

Illustrative: a build dispatch on a Kotlin service. Its `>` marks only set it apart here and are not part of the report.

> ## Implementation Report
>
> **Technology:** Kotlin 2.0, Ktor 3
>
> **Files created/modified**
>
> - `src/order/RateLimiter.kt` — per-customer request limit
> - `src/order/OrderRoutes.kt` — applies the limit to POST /orders
>
> **What was implemented**
>
> POST /orders now answers a customer's 11th request in a minute with 429, so one client can't starve the rest.
>
> **Key decisions**
>
> - Counters kept in memory per customer ID: kept in file: why they reset each minute; for the commit message: a shared store is the follow-up.
>
> **Verification**
>
> - format pass · lint pass (0 warnings) · type check pass · test pass (22) · build pass
>
> **Open blockers:** none
>
> **Open points**
>
> - Assumed the limit is per customer, not per API key: the brief didn't say.
>
> **Handoff to reviewer**
>
> - Focus: concurrent access to the counters in `RateLimiter.kt`.
> - Trade-off: the limits reset when the service restarts.

## Example: a fix round

Illustrative: the finding lines of a fix round with two findings, before the heading.

> KT-003 (HIGH) — fixed: place() now rethrows PaymentException as OrderFailed.
>
> KT-007 (LOW) — not fixed (proposal): the retry count stays at 2; the gateway's own limit is 3.
