---
name: standard-python
description: The single definition of idiomatic, correct Python — the shared language rubric that the python-developer BUILDS to and the python-reviewer REVIEWS against. Applies whenever Python code is written, changed, or reviewed (general-purpose scripts, CLI tools, libraries/packages, automation, data-processing pipelines — stdlib-leaning, no specific web framework assumed). Defines mutable-state and binding-semantics traps (default arguments, class attributes, closures), modern type-hint idioms and data modeling, error handling and resource management, concurrency and parallelism correctness (the GIL and its misconceptions), equality/hashing/numeric-comparison traps, import structure and module-loading hazards, iterator/generator semantics, idiomatic constructs, project structure and packaging, micro-performance and allocation hygiene, and lint/type-check/format discipline. This is WHAT good Python looks like; it does not define builder workflow (build-core), the reviewer's correctness-detective method / scope-boundary / severity / category vocabulary (the python-reviewer), or the build/report envelopes (build-report-standards / review-report-standards).
---

# Standard: Python

The **one** definition of what good, correct Python looks like. The `python-developer` builds to it; the `python-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we write Python and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like** — the idioms to reach for and the traps to avoid. It is **NOT a Python tutorial**: assume fluent Python, and encode only the non-default priorities and easy-to-miss pitfalls. It deliberately does NOT contain: the builder's workflow (`build-core`) or the reviewer's machinery — the correctness-detective method, scope-boundary/handoff, severity, and `category` vocabulary live with the `python-reviewer`; report envelopes live in `build-report-standards` / `review-report-standards`.

Assume **Python 3.12+ as the floor** (idioms validated against 3.13) unless the project states otherwise. This standard is framework-agnostic by design — no specific web/async framework is assumed; apply it to scripts, CLI tools, libraries, and general application code alike.

## Mutable State & Binding Semantics (the #1 correctness surface)

Python's most notorious footguns are all instances of the same mistake — treating a value that is created **once** as if it were created **per call / per instance**:

- **Mutable default arguments** — `def f(x, acc=[])` evaluates the default **once**, at `def` time, and every call that omits `acc` shares that **same** list object; mutations from one call leak into the next. Fix: default to `None` and materialize the mutable value inside the function body; for dataclasses, use `field(default_factory=list)` rather than a bare mutable default.
- **Class-level mutable attribute defaults** — `class Foo: items = []` is **one** object shared by every instance, not a per-instance default. Ruff's `RUF012` exists specifically to catch this. Fix: initialize the attribute in `__init__`, or mark genuinely-intentional sharing explicitly with `ClassVar`.
- **Late-binding closures in loops** — `[lambda: i for i in range(5)]` produces five lambdas that all close over the **same** variable `i`, so all five return the loop's final value, not the value at creation time. Fix: default-argument capture (`lambda i=i: i`) or `functools.partial`.

Treat any of these as a defect regardless of whether it currently "happens to work" — the shared-state bug is dormant until a caller passes no argument, mutates the shared default, or the closure is invoked after the loop completes.

## Type Hints & Data Modeling

- Typing in Python is **gradual**: annotations exist for static tools, editors, and documentation — they are not enforced at runtime. Require type hints on public signatures; do not chase 100%-strict typing unless the project has explicitly opted into it.
- **Modern syntax supersedes older forms for new code**: built-in generics (`list[int]`, `dict[str, str]`) over `typing.List`/`typing.Dict` (deprecated); `X | Y` / `X | None` (PEP 604) over `typing.Union`/`typing.Optional`; PEP 695 generics (`class Stack[T]:`, `type Vector = list[float]`) over `TypeVar`/`Generic`/`TypeAlias` on 3.12+ codebases; `collections.abc.Callable` over `typing.Callable`; `typing.Protocol` for structural typing instead of forcing an inheritance hierarchy where duck typing is the real contract; `TypedDict` with `NotRequired`/`ReadOnly` for fixed-shape dict data.
- **Dataclasses vs. `NamedTuple`**: reach for `@dataclass` when the type needs behavior or customization (mutable by default; `frozen=True, slots=True` gets you a near-`NamedTuple`-equivalent — immutable, no per-instance `__dict__`). Reach for `NamedTuple` for a lightweight, genuinely immutable, tuple-unpacking record. `copy.replace()` (3.13+) works on both — prefer it over hand-rolled "copy with one field changed" helpers.
- Static checkers are **complementary, not either/or**: `mypy` is the reference implementation and the common CI/library choice; Pyright is faster and ubiquitous in editors (via Pylance). A typical setup is Pyright in-editor for fast feedback, with `mypy` (or Pyright in CI mode) as the actual gate. Either is acceptable as the enforcement mechanism — "a static type checker passes in CI" is the requirement, not a specific tool.

## Error Handling & Resource Management

- **Never a bare `except:` or `except Exception: pass`.** Either swallows everything — including `KeyboardInterrupt` and `SystemExit` — and discards real bugs with zero trace. Catch the narrowest exception type the call site can actually handle; when you can't handle it, log with context and re-raise rather than swallowing it.
- **Never `return` / `break` / `continue` inside a `finally` block.** It unconditionally discards any exception still propagating from the `try`/`except`, and the function silently returns/loops normally instead of surfacing the failure. This is flagged by Pylint, Ruff, and flake8-bugbear, and Python 3.14 added a `SyntaxWarning` for it — treat it as a defect, not a style nit.
- **Always use `with` for anything with acquire/release semantics**, never a manual `.close()` — an exception raised between acquire and close skips the manual cleanup, leaking file descriptors (eventually exhausting the process's FD limit) or locks (causing deadlock). Use a class-based context manager (`__enter__`/`__exit__`) for stateful resources, `@contextlib.contextmanager` for a simple generator-based one, and `contextlib.ExitStack` when the set of resources to manage is dynamic or plural.

## Concurrency & Parallelism

- **The GIL gives concurrency, not parallelism, for CPU-bound work.** Threading helps for I/O-bound work (the GIL is released around blocking I/O) but does not speed up — and can even slow down — CPU-bound work under multiple threads. In `asyncio`, a single blocking (non-awaiting) call freezes the **entire** event loop, not just the task that made it. Match the tool to the workload: `asyncio` for I/O with async-native libraries, plain `threading` for I/O against blocking libraries, and `multiprocessing` (or `asyncio.to_thread` to offload from an event loop) for genuinely CPU-bound work.
- **The GIL does not make compound operations atomic.** `counter += 1` is a load-modify-store sequence; without synchronization, concurrent threads can interleave and lose updates even though "the GIL protects Python" is a common misconception. Guard any compound read-modify-write shared across threads with `Lock`/`RLock`, or route it through `queue.Queue`.
- **`fork` vs. `spawn` carry different, easy-to-miss assumptions about inherited state.** A `fork`ed child inherits the parent's state as of the fork instant — including a mutex the parent held locked, now with no thread present to ever release it. A `spawn`ed child does **not** inherit parent module-level state built up before the spawn call, and requires all arguments to be picklable. This is platform-dependent (macOS and Windows default to `spawn`; Linux has historically defaulted to `fork`), so the same code can pass in CI on one OS and fail in production on another — do not write multiprocessing code that silently assumes one start method.

## Equality, Hashing & Numeric Comparison — Traps That Don't Look Like Traps

These all run without raising an exception and produce a plausible-looking wrong answer:

- **`is` is identity, not value equality.** CPython's small-integer and string interning/caching makes `is` comparisons on such values pass in casual testing, then silently break the moment a real or computed value crosses the cache boundary. Use `==`/`!=` for value comparison; reserve `is` for singleton checks (`is None`, `is True`, `is False`).
- **The `__eq__`/`__hash__` contract**: `x == y` must imply `hash(x) == hash(y)`. Hashing a mutable object — or a custom `__eq__` that compares mutable fields — corrupts `set`/`dict` bucket placement: after the object mutates, it becomes unfindable by an equal-valued lookup even though it is still discoverable via `in` iteration. Keep hashable types' equality-relevant fields immutable, or don't make the type hashable.
- **Floating-point precision**: IEEE-754 floats cannot exactly represent most decimal values (`0.1 + 0.2 != 0.3`). Direct `==` on computed floats is unreliable, and dangerous in financial or accounting code. Use `decimal.Decimal` for exact-decimal domains, and `math.isclose()` when comparing computed floats.
- **NaN comparison semantics**: `nan == nan` is `False` by the IEEE-754 spec. Sort, dedupe, or sentinel logic that uses bare `==`/`in` against a NaN value will silently misbehave. Use `math.isnan()` (or `pandas.isna()` in a pandas context) instead.

## Imports & Module Structure

- **Circular imports and import-time side effects** produce a partially-initialized module object when module A and module B import each other before either finishes executing its own top level. The failure is order-dependent — whichever entry point happens to run first determines whether the circularity is even triggered, so it can pass locally and fail only from a different entry point. Fix by deferring the import (move it inside the function that needs it), restructuring shared symbols out into a module neither side needs to import from the other, or importing the whole module (`import x`) rather than pulling a name out of it (`from x import y`) so the binding is resolved lazily at use time.

## Iterators & Generators

- **A generator is single-use.** Re-iterating an already-exhausted generator raises no error — it silently yields nothing. Treat "did this iterable get consumed already" as a real question when a generator is passed around or reused across branches.
- **`StopIteration` inside a generator body is not "just an exception."** Pre-3.7, an unguarded `StopIteration` escaping a generator body was silently treated as normal generator completion — a real bug class. PEP 479 turned this into a loud `RuntimeError` starting in Python 3.7, but the underlying mistake (letting an inner iterator's exhaustion propagate unexamined) is still worth flagging in review, since the loud failure is a symptom, not the fix.

## Idiomatic Constructs

**`pathlib` over `os.path`** — object-oriented, cross-platform, consolidates what used to require `os`/`os.path`/`glob`/`open` into one API; genuinely reduces cross-platform path bugs (string-based path building is a real portability trap), not just a style preference. (f-strings and comprehensions are tutorial-level defaults, not non-obvious priorities — deliberately not listed here. Naming conventions are Ruff's job — see Lint, Type-Checking & Formatting Discipline below; not re-derived here.)

## Project Structure & Packaging

- **`pyproject.toml`** (PEP 518/621) is the universal, standardized project config — every modern tool reads its `[project]` table consistently (Poetry adopted this convention in its 2.0+ line). Prefer it over tool-specific config files scattered across the repo.
- **src-layout is the safer default for anything packaged or distributed** — it forces install-before-run, prevents accidentally importing the uninstalled local copy, and keeps non-package files off the import path. Flat-layout remains acceptable for quick scripts and single-file tools where there is nothing to accidentally shadow.
- **`pytest`** is the de facto standard test framework — fixtures, parametrization, and its plugin ecosystem make it the default choice over stdlib `unittest` for new projects.

## Micro-Performance & Allocation Hygiene

Language-level hygiene only — algorithmic complexity is lens-performance's job, not this file's:

- Prefer a generator expression over a fully-materialized list/comprehension when the data is consumed once and not indexed or iterated twice — avoids holding the whole sequence in memory.
- The `frozen=True, slots=True` combination noted in Type Hints & Data Modeling also cuts memory at scale (removes the per-instance `__dict__`) — worth reaching for deliberately when a dataclass is instantiated in volume, not just as a style default.
- Build strings with `str.join()` rather than repeated `+=` concatenation in a loop — repeated concatenation on an immutable `str` reallocates on every append.

## Lint, Type-Checking & Formatting Discipline

- **Ruff is the standard, consolidated tool**: it folds together what used to be separate flake8, isort, pyupgrade, and a subset of Bandit's checks, plus a Black-compatible formatter, into a single fast binary. Standalone Black is an acceptable slower alternative; standalone flake8/isort/pyupgrade are legacy for new projects. Standalone Pylint still has some deeper checks a minority of teams retain it for, but Ruff's `PL` rules subsume most of it.
- **Style/PEP-8 conformance is Ruff's job, not a manual review job** — the reviewer should flag missing or broken tooling conformance (a `ruff check`/`ruff format --check` failure), not manually re-derive PEP 8 rule-by-rule.
- **Ruff's own `S` (security) rules are a partial reimplementation of Bandit's checks, not a full port.** Keep a real `bandit` run in CI as defense-in-depth when full security-rule coverage matters — do not treat Ruff's `S` rules as a complete substitute.
- The "clean" bar: `ruff format --check` and `ruff check` both exit 0, and a static type checker (`mypy` or Pyright) passes in CI. An unjustified `# noqa` / `# type: ignore` suppression is a defect the same way an unjustified lint-suppression is in any other language this repo builds.

---
*Standard Version: 1.0 — the shared Python rubric. Built to by the python-developer (via build-core); reviewed against by the python-reviewer.*
