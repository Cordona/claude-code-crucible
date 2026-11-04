# Spring: development

## Edge cases

- **A Kotlin class Spring proxies or JPA instantiates, with the compiler plugin it needs not enabled in the build:** make no project-wide change (enabling the compiler plugin in the build file) unless the task covers it; record the change the code needs, with the file it goes in where that file exists.

## Self-check before reporting

1. The Spring Boot version was settled in the Toolchain order.
2. Constructor injection only: no field `@Autowired`.
3. `@Transactional` sits on services, and no transaction relies on a self-invocation.
4. No lazy association is loaded outside a transaction.
5. The Spring Security request rules deny by default, and CSRF stays on for a browser session.
6. Where Spring proxies or JPA instantiates a Kotlin class, the compiler plugin it needs is enabled, or the needed change is recorded.
