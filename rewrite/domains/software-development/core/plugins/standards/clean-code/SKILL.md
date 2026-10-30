---
name: standard-clean-code
description: The structural rubric for clean code in any language, tests included — honest contracts, one responsibility, cohesion, DRY weighed against YAGNI, low coupling, small flat functions, no dead code, top-down file layout. Injected into the agent's first message when loaded. Writes nothing. Not for naming or comments (standard-self-documenting-code), test names and test-only rules (standard-testing), performance (standard-performance) or a language's or framework's idioms (its language or framework plugin).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Clean code
---

# Standard: Clean Code

What well-structured code looks like, in any language. The developer builds to these rules, then follows `references/development.md`; a reviewer (once a review flow dispatches `code-reviewer`) judges by the same rules, then follows `references/review.md`. Both receive this file in their prompt, with their role's reference file right after it.

## Scope

- **In:** all code the developer writes or changes, test code included.
- **Project conventions:** follow the project's structural conventions: its module boundaries, its tolerance for function length and file size, its names for abstraction layers. Never impose a foreign architecture. A convention never excuses a real violation: a SOLID, DRY or coupling violation with a nameable harm is a defect even where the project does the same.

## Reading the rules

- **When two rules pull against each other, name the trade-off:** these rules conflict by design, so a choice between them is stated, not hidden.

Most consequential first: a broken contract or a hidden side effect changes behaviour; the rest change how hard the code is to change.

## 1. Contracts and side effects

- **Honour the supertype's contract (Liskov):** a subtype or implementation never throws where its base doesn't, never accepts narrower inputs, and never weakens what the base guarantees.
- **A method either does something or answers something, never both (command-query separation):** no hidden side effect behind a getter. A real builder or accumulator is exempt.

## 2. Responsibility and cohesion

- **One responsibility per unit:** a function does one thing; a class has one reason to change.
- **Keep together what belongs together:** the code for one concept lives in one unit, not spread across several. It is the twin of one responsibility.
- **No flag parameters:** a boolean that switches a function between two behaviours is two functions; split them.

## 3. Duplication and abstraction

- **Extract duplicated logic** into one named unit and call it from every site. A block about to be copied and tweaked wants to be a function.
- **Abstract only for 2 or more callers that exist in the code now, that change together:** blocks that look alike but change for different reasons are not duplication. A little duplication costs less than the wrong abstraction.
- **Replace a growing type-tag chain with polymorphism or a strategy:** when a `switch` or `if` chain on a type tag grows with every new case, make each case its own type.
- **Add no extension point for a variation that doesn't exist yet:** the simple version beats a speculative one.

## 4. Coupling

- **Talk to immediate collaborators (Law of Demeter):** no `a.getB().getC().doThing()` chains; ask the collaborator to do the work.
- **Depend on abstractions:** inject collaborators. Never reach into another module's concrete types or hidden globals, or construct a concrete collaborator deep in business logic.
- **Keep interfaces narrow (interface segregation):** no interface that forces clients onto methods they don't use, and no unused method stubs.

## 5. Functions

- **Keep functions short,** about 20–30 lines or fewer; extract when a function takes on a second job. The figure is a trigger to look, not a limit: a cohesive function that does one thing may be longer.
- **Handle edge cases first with guard clauses** and return early; never wrap the body in nested `if`s.
- **Nest at most about 3 levels;** deeper is a sign to extract.
- **Take few parameters,** 3 or fewer by preference; bundle related ones into an object or struct.
- **Extract to name a concept or to remove duplication,** never only to meet a line count. A block that seems to need a comment saying what it does is a sign it wants a named function of its own.

## 6. Dead code

- **Ship only code that runs:** no unused functions, parameters or imports, and no unreachable branch kept just in case. Version control keeps the history, and dead code misleads the next reader.

## 7. File layout

Order each file so a reader meets the intent first and the details after (the stepdown rule):

- Public and entry-point declarations first, private helpers after.
- Private helpers in the order they are first called, caller before callee, so following the flow never means jumping back.
- A wrapper before the function it wraps; leaf utilities last.
- A type beside the code that immediately consumes it.
- **Where the language forces another order,** such as a declaration that must precede its use (a temporal dead zone or a forward-reference rule), follow the language.
- This order is the language-agnostic default; per-language layout idioms (test-module placement, constant blocks, import order, member order) are out of this standard.
