---
name: framework-spring
description: "Spring rules: Boot toolchain, injection, transactions, JPA, the web boundary, Security and the compiler plugins Spring needs. Use when writing or reviewing Kotlin that uses Spring Boot, Spring Data or Spring Security. A framework plugin beside its language plugin. Writes nothing and adds no gate tool. Not for code with no language plugin loaded, Java, other JVM frameworks (Ktor, Micronaut), or Kotlin's own rules (`language-kotlin`)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: Spring
---

# Framework: Spring

The rules that are specific to Spring. It loads beside `language-kotlin`, never alone, and repeats no rule that plugin holds. Every role receives this file in its first message, after the language plugin's. A developer then receives `references/development.md` right after it: what to report, the defaults, the edge cases and the verification gate. A reviewer receives `references/review.md` right after it instead: how to judge a finding and how to grade it.

## Scope

- **In:** Spring Framework, Spring Boot, Spring Data (Spring Data JPA included) and Spring Security, used from Kotlin.
- **In, with no rules of their own:** other Spring projects, such as WebFlux and Spring Cloud: the rules below apply where they fit.
- **Out:** Spring code with no language plugin loaded: this plugin never loads alone.
- **Out:** Spring code in Java: this file holds no rules for it.
- **Out:** other JVM frameworks: Micronaut, Quarkus, Jakarta EE without Spring, Ktor, Exposed.

## Toolchain

Settle it after the language plugin's toolchain, before writing a line. Take each fact from the first source below that sets it:

1. The Spring Boot version in the build: the `org.springframework.boot` Gradle plugin, Maven's `spring-boot-starter-parent` or the `spring-boot-dependencies` BOM, or the version catalog.
2. What the project's own docs on its Spring code say, where the task's context lists them.
3. Otherwise Spring Boot 3.x (see Version ledger).

## With Kotlin

- **The `kotlin-spring` (all-open) and `kotlin-jpa` (no-arg) compiler plugins are needed:** Kotlin classes are `final` with no no-arg constructor, which breaks CGLIB proxies and JPA entities. With one not enabled, see the developer's edge cases.

## Transactions

- **`@Transactional` on services,** not on controllers or repositories: the service method is the unit of work; a repository transaction splits it, and a controller one holds the connection through the web layer.
- **`readOnly = true` for queries:** Hibernate then skips dirty checking and the flush.
- **Never rely on a self-invocation for a transaction:** a call from inside the same bean bypasses the proxy, so `@Transactional` does nothing on that call.

## JPA

- **Declare every association `LAZY`,** collections, `@ManyToOne` and `@OneToOne` included: JPA defaults the last two to `EAGER`, and an eager collection is a fetch-strategy defect.
- **Load a lazy association only inside its transaction:** outside it, Hibernate throws `LazyInitializationException`.

## Spring Security

- **Deny by default:** end the request rules with `anyRequest().denyAll()`, so a path no rule names stays closed; end them with `anyRequest().authenticated()` only when every signed-in user may reach every path no rule names.
- **Narrow matchers before broad ones:** matchers are checked in order and the first match wins, so a broad matcher first opens the narrow path.
- **CSRF protection stays on for a browser session:** disable it only for a stateless API with no cookie-based login.
- **Passwords go through a `PasswordEncoder`** that hashes with the algorithm `standard-security` holds, loaded only when the task's plan loads it: never `NoOpPasswordEncoder` or plain text.
- **`@PreAuthorize` needs `@EnableMethodSecurity`:** without it the annotation does nothing.
- **Never rely on a self-invocation for `@PreAuthorize`:** as with `@Transactional`, a call from inside the same bean skips it.

## Web boundary

- **`@Valid` at controller boundaries,** with Jakarta Bean Validation: without it the request body's constraints never run.
- **Error responses through `@RestControllerAdvice` with `ProblemDetail`:** one handler gives every error the same problem-details body and leaks no stack trace.

## Dependency injection

- **Constructor injection, never field `@Autowired`:** a field-injected dependency can't be a `val`, and a test can't set it without the container.

## Spring mechanisms for the shared standards

- **Queries:** parameterized through Spring Data `@Query` with named parameters; JPA Criteria only when the query is built at run time.
- **Persistence:**
  - `@Transactional` boundaries scoped tight;
  - optimistic `@Version` against lost updates;
  - `@EntityGraph` on the repository method over a lazy relation walked per row; a fetch join in `@Query` when the query is already hand-written;
  - keyset pagination through Spring Data's `ScrollPosition` and `Window` API where the build's Spring Data has it (see Version ledger); otherwise a `@Query` with `WHERE (col) > :last ORDER BY col`.

## Lints

- **Spring adds no lint of its own:** the language plugin's Lints apply.

## Version ledger

| Fact | Value | Last verified |
|---|---|---|
| Default Spring Boot major (Toolchain step 3) | 3 | not verified by a command: the legacy default, kept on 2026-10-30 |
| `ScrollPosition` and `Window` available from | unknown | not verified by a command: no source read names the version, kept on 2026-10-30 |
