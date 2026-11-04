# Rust: review

## Correctness

- **Check for these Rust correctness defects:**
  - wrong conditions and off-by-one in ranges, indexing and slicing;
  - a `match` that breaks the exhaustiveness rule;
  - dropped fallibility.

## How to judge

- **A break of the std trait contracts, or of the Arithmetic and casts rules, is a correctness defect.**
- **Judge `unsafe` as soundness, not a checklist:** can any safe caller, with any input, reach the UB inside? Then the abstraction is unsound, even when each `unsafe` block looks right on its own.
- **Check each `unsafe` block for:**
  - aliasing: overlapping `&mut`, aliased raw pointers; suggest `cargo +nightly miri test`;
  - `transmute` with unchecked layout, validity or lifetime, `MaybeUninit::assume_init` too early, a read of uninitialised memory;
  - a hand-written `unsafe impl Send` or `Sync` the type can't back;
  - drop safety: a double drop or use after drop (`ptr::read`, `ManuallyDrop`), a panic in `Drop` during unwind;
  - a break of the FFI panic rule.
- **A safe leak is not UB:** an `Rc` or `Arc` cycle, `mem::forget`, a forgotten `JoinHandle`.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.

## Severity

- **CRITICAL:**
  - unsound `unsafe`: aliasing, `transmute` or uninitialised memory, a double drop, a false `Send` or `Sync`;
  - a possible data race (undefined behaviour);
  - exploitable injection: SQL built from untrusted input, against the Queries mechanism.
- **HIGH:**
  - `unwrap()`, `expect()` or `panic!()` in library code;
  - I/O with no timeout.
- **MEDIUM:**
  - a safe leak, as defined above;
  - an unpinned dependency or another supply-chain gap, against the Supply chain mechanism;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - an unnecessary clone off the hot path;
  - a clippy style warning;
  - a secret held in memory outside the Secrets in memory mechanism (`secrecy`, `zeroize`);
  - a suppression with no written reason.

**Overrides:**
- **FFI and `unsafe`:** hold them to the strictest bar.

**What moves a level:**
- An unnecessary clone rises above LOW only when it sits on a measured hot path.
