# Clean code: development

Apply after `SKILL.md`'s rules, before writing code.

## Reporting

- **State each extraction's gain and cost** in the report's Key decisions field: an extraction trades one place to change for one more call to follow, and the reviewer judges it by that trade. Example: `Extracted buildRows(): CSV and JSON share one totals rule; costs one more call to follow.`

## Self-check before reporting

1. No subtype breaks its base's contract, and no method both changes state and answers (builders and accumulators aside).
2. Each unit has one responsibility, and the code for one concept sits in one unit.
3. Every new abstraction has 2 or more callers that exist in the code now, that change together, and each extraction's gain and cost is in Key decisions.
4. No flag parameter, message chain, hidden global, or concrete collaborator built deep in business logic.
5. Every function over about 30 lines, nested deeper than about 3 levels, or taking more than 3 parameters was checked for a second job.
6. No unused function, parameter, import or unreachable branch is left.
7. Each file reads top-down, or follows an order its language forces.

A failed item: fix it, then run the check again.
