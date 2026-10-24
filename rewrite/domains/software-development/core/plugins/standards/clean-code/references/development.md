# Clean code: development

Apply after `SKILL.md`'s rules, before writing code.

## Reporting

`standard-code-development-report` sets each item's shape.

- **Each extraction's gain and cost** -> the report's `decisions`, because an extraction trades one place to change for one more call to follow, and the reviewer judges it by that trade.

## Self-check before reporting

1. No subtype breaks its base's contract, and no method both changes state and answers (builders and accumulators aside).
2. Each unit has one responsibility, and the code for one concept sits in one unit.
3. Every new abstraction has 2 or more callers that exist in the code now, that change together.
4. No flag parameter, message chain, hidden global, or concrete collaborator built deep in business logic.
5. Every function over about 30 lines, nested deeper than about 3 levels, or taking more than 3 parameters was checked for a second job.
6. No unused function, parameter, import or unreachable branch is left.
7. Each file reads top-down, or follows an order its language forces.
8. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
