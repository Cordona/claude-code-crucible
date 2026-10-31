# Rust: review

Apply with `SKILL.md`'s rules when judging Rust: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness for Rust:** this language plugin, with any framework plugins loaded beside it, judges whether the code does what it is meant to. Check for:
  - wrong conditions and off-by-one in ranges, indexing and slicing;
  - a `match` that breaks `SKILL.md`'s exhaustiveness rule;
  - dropped fallibility;
  - unhappy paths that do the wrong thing;
  - a break of the code's stated invariants;
  - boundary and error paths that are incomplete;
  - behaviour that breaks its intended contract.

## How to judge

- **A break of `SKILL.md`'s std trait contracts, or of its Arithmetic and casts rules, is a correctness defect.**
- **Judge `unsafe` as soundness, not a checklist:** can any safe caller, with any input, reach the UB inside? Then the abstraction is unsound, even when each `unsafe` block looks right on its own.
- **Check each `unsafe` block for:**
  - aliasing: overlapping `&mut`, aliased raw pointers; suggest `cargo +nightly miri test`;
  - `transmute` with unchecked layout, validity or lifetime, `MaybeUninit::assume_init` too early, a read of uninitialised memory;
  - a hand-written `unsafe impl Send` or `Sync` the type can't back;
  - drop safety: a double drop or use after drop (`ptr::read`, `ManuallyDrop`), a panic in `Drop` during unwind;
  - a break of `SKILL.md`'s FFI panic rule.
- **A safe leak is not UB:** an `Rc` or `Arc` cycle, `mem::forget`, a forgotten `JoinHandle`.
- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.
- **Verify a crate API or version-specific behaviour against its current docs** before filing a finding that turns on it, never from memory alone.

## Severity

Where a Rust defect usually lands on the four levels. Start here, then judge the case in front of you.

- **CRITICAL:**
  - unsound `unsafe`: aliasing, `transmute` or uninitialised memory, a double drop, a false `Send` or `Sync`;
  - a possible data race (undefined behaviour);
  - exploitable injection: SQL built from untrusted input, against `SKILL.md`'s Queries mechanism.
- **HIGH:**
  - a correctness defect from Correctness above;
  - `unwrap()`, `expect()` or `panic!()` in library code;
  - I/O with no timeout.
- **MEDIUM:**
  - a safe leak, as defined above;
  - an unpinned dependency or another supply-chain gap, against `SKILL.md`'s Supply chain mechanism;
  - a rule turned off or down in the project's lint config.
- **LOW:**
  - an unnecessary clone off the hot path;
  - a clippy style warning;
  - a secret held in memory outside `SKILL.md`'s Secrets in memory mechanism (`secrecy`, `zeroize`);
  - a suppression with no written reason.

**Overrides:**
- **Test code:** a build diff that changes test code, a test module inside a source file included, is HIGH, as `code-reviewer` sets; no rule here grades test code lower.
- **FFI and `unsafe`:** hold them to the strictest bar.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
- Injection and remote code execution drop to HIGH when exploiting them is harder or reaches less.
- An unnecessary clone rises above LOW only when it sits on a measured hot path.
