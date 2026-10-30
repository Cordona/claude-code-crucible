# Rust: review

Apply with `SKILL.md`'s rules when judging Rust: review correctness first, by the first bullet below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

- **The tech lens owns correctness for Rust:** this language plugin, with any framework plugins loaded beside it, judges whether the code does what it is meant to. Check for wrong conditions and off-by-one in ranges, indexing and slicing; a `match` that breaks `SKILL.md`'s exhaustiveness rule; dropped fallibility; unhappy paths that do the wrong thing; behaviour that breaks its documented contract or stated invariants.
- **A break of `SKILL.md`'s std trait contracts, or of its Arithmetic and casts rules, is a correctness defect.**
- **Judge `unsafe` as soundness, not a checklist:** can any safe caller, with any input, reach the UB inside? Then the abstraction is unsound, even when each `unsafe` block looks right on its own.
- **Check each `unsafe` block for:**
  - aliasing: overlapping `&mut`, aliased raw pointers; suggest `cargo +nightly miri test`;
  - `transmute` with unchecked layout, validity or lifetime, `MaybeUninit::assume_init` too early, a read of uninitialised memory;
  - a hand-written `unsafe impl Send` or `Sync` the type can't back;
  - drop safety: a double drop or use after drop (`ptr::read`, `ManuallyDrop`), a panic in `Drop` during unwind;
  - a break of `SKILL.md`'s FFI panic rule.
- **A safe leak is not UB:** an `Rc` or `Arc` cycle, `mem::forget`, a forgotten `JoinHandle`.
- **Verify a crate API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a Rust defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - unsound `unsafe`: aliasing, `transmute` or uninitialised memory, a double drop, a false `Send` or `Sync`;
  - a possible data race.
- **HIGH:**
  - a correctness defect;
  - `unwrap()`, `expect()` or `panic!()` in library code;
  - I/O with no timeout.
- **MEDIUM:**
  - a safe leak, as defined above.
- **LOW:**
  - an unnecessary clone off the hot path;
  - a clippy style warning.

**Overrides:**
- Test code may `unwrap`: grade it lower, and note the better pattern.
- FFI and `unsafe`: hold them to the strictest bar.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- An unnecessary clone rises above LOW only when it sits on a measured hot path.
