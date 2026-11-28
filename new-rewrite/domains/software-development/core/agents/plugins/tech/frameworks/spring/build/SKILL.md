---
name: framework-spring-build
description: "Spring rules for a build job agent, preloaded through its agent file. Not for main."
user-invocable: false
metadata:
  label: Spring, build
---

# Spring: build

## Edge cases

- **A Kotlin class Spring proxies or JPA instantiates, with the compiler plugin it needs not enabled in the build:** make no project-wide change (enabling the compiler plugin in the build file) unless the task covers it; record the change the code needs, with the file it goes in where that file exists.
