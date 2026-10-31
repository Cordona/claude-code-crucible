# Spring: development

Apply after `SKILL.md`'s rules, beside the language plugin's development rules, before writing any Spring code.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The Spring Boot version found** -> the report's `toolchain`, beside the language toolchain, because the reviewer judges the code against the Spring Boot version it names.
- **The `verification` items are the language plugin's gate items:** this plugin adds none.

## Defaults when the first message is silent

- **The Spring Boot version** comes from `SKILL.md`'s Toolchain order.

## Edge cases

- **A Kotlin class Spring proxies or JPA instantiates, with the compiler plugin it needs not enabled in the build:** make no project-wide change (the build file, a compiler plugin) unless the task covers it; record the change the code needs in the report's `noticed`.

## Verification gate

The language plugin's gate covers Spring code: its compile check and existing tests run through the build tool. This plugin adds no step and no tool.

## Self-check before reporting

1. The Spring Boot version was settled in `SKILL.md`'s Toolchain order.
2. Constructor injection only: no field `@Autowired`.
3. `@Transactional` sits on services, and no transaction relies on a self-invocation.
4. No lazy association is loaded outside a transaction.
5. The Spring Security request rules deny by default, and CSRF stays on for a browser session.
6. Where Spring proxies or JPA instantiates a Kotlin class, the compiler plugin it needs is enabled, or the needed change is in `noticed`.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
