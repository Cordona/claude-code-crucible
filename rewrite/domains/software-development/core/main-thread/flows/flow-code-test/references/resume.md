# Resume: a tester seat after a break

Its terms and steps are SKILL.md's. Run for every tester seat `flow-code-build`'s Resume hands here, whatever its status, one seat at a time (SKILL.md Always, one gate at a time), once SKILL.md's Resume has loaded `procedure-seat-run` with the tester's inputs. The seat's build seat is its `build_seat` in the seat list. Nothing is sent on an approval only the effort's events still show.

1. **The seat:** its status from SKILL.md step 2's `seats.sh get` of the tester seat; a non-zero exit: show its stderr, and record the part `not checked`.
   - **`open`** (joined or handed over, no agent on it): straight to SKILL.md step 3, its `open` case, never through `procedure-seat-run`'s Resume; step 3 builds the task and starts the todo item.
   - **Any other status:** follow `procedure-seat-run`'s Resume for this seat only (its single-seat entry, "take up seat S"), which takes a `working` or `gave-up` seat up itself and checks an `idle` one's result and gate. Act on what it hands back:
     - **A result it took up:** SKILL.md step 4's Results.
     - **`planned`, or a plan with a blocker** (its newest result a plan): run the plan check (SKILL.md Terms). `ANSWER:` `Agree, no tests` or `Stop` (matched with `(Recommended)` ignored): the part is closed, nothing is asked. Otherwise the plan card again (SKILL.md Terms), then SKILL.md step 5, whatever an earlier answer was; TEST comes only from that gate's answer in this conversation. A non-zero exit: show its stderr, and record the part `not checked`.
     - **The label `test-next`,** with `gate-answered.sh`'s `ANSWERED:` and `ANSWER:` lines: `ANSWERED: no` (its test report's gate never answered): the test card again (SKILL.md Terms), then SKILL.md step 7; `ANSWERED: yes`: nothing is asked.
     - **Anything else** (a record, or nothing to ask): nothing is asked; its card only when the human asks.
2. **Then** go on from SKILL.md Close.
