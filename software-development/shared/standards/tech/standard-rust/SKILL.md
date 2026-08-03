---
name: standard-rust
description: The single definition of good Rust — the shared rubric the Rust developer builds to and the Rust reviewer judges against. Covers ownership/borrowing, error handling, arithmetic overflow & lossy casts, the type system, std trait contracts, traits/generics, lifetimes, concurrency, the unsafe principle, async hazards, iterators/idioms, allocations, and lint/format discipline. This is WHAT good Rust looks like; it does NOT define builder workflow (build-core), the reviewer's correctness-detective method, the unsafe soundness-analysis method, or reviewer scoring — severity, category vocabulary, and false-positive guards live in the rust-reviewer.
---

# Standard: Rust

The **one** definition of good Rust. The `rust-developer` builds to it; the `rust-reviewer` judges against it. Because both bind this single skill, there is no daylight between how we write Rust and how we review it — a rule changed here moves both sides at once.

This skill defines **WHAT good looks like** — idioms, traps, and language-level safety/correctness principles. It deliberately does NOT contain: the builder's workflow and validation gate (that is `build-core` + the developer body), or the reviewer's machinery — the correctness-detective method, the `unsafe` soundness-analysis method (`miri`, reachability), severity, `category` vocabulary, scope-boundary/handoff, and false-positive guards all live in the `rust-reviewer`.

**Framing:** each item states what **Good Rust** does and what a **defect** is — read it as a build target or a review rubric interchangeably. Not a tutorial: only the non-default priorities and the easy-to-miss traps.

## 1. Ownership & Borrowing

- Good Rust **borrows over cloning** — `&T`, `&str` over `String`, `&[T]` over `Vec<T>`; move to transfer ownership, borrow to share.
- Use `Cow<'a, T>` for conditional ownership (borrow in the common case, own only when mutation is needed).
- Interior mutability (`RefCell` / `Cell` / `Mutex`) is justified deliberately, not reached for by habit.
- A defect: gratuitous clones/allocations where a reference would do; **fighting the borrow checker** repeatedly signals a design smell, not a case for `.clone()` sprinkling.

## 2. Error Handling

- Fallible work returns `Result<T, E>`; propagate with `?` in preference to `match` boilerplate.
- Custom error types with `thiserror` in **libraries**; `anyhow` / `color-eyre` in **binaries / CLIs**.
- **NEVER `unwrap()` / `expect()` / `panic!()` in library code** — return `Result`. (Test code may `unwrap`, at lower severity, though better patterns still apply.)

## 3. Arithmetic & Numeric Conversions

- Integer overflow **panics in debug but silently wraps in release** — choose `checked_*` / `saturating_*` / `wrapping_*` **deliberately** for any value that can exceed its type's bounds.
- **Lossy `as` casts** are a trap: `usize as u32`, `i64 as i32`, float↔int silently truncate/wrap. Prefer `TryFrom` / `try_into` at boundaries so an out-of-range value is an error, not silent corruption.
- (Overflow with a security consequence — fraud, over-allocation, OOB index — is a security concern, not merely arithmetic.)

## 4. Type System

- **Newtypes** for domain concepts (`UserId(Uuid)`) instead of bare primitives.
- **Enums** for state machines and closed variant sets; `Option<T>` instead of null/sentinel.
- **const generics** where they buy compile-time safety.
- Lean on the type system for compile-time correctness — make illegal states unrepresentable.

## 5. std Trait Contracts

Breaking a standard-library trait contract silently corrupts `HashMap` / `BTreeMap` / sorts — a defect regardless of style:

- **`Eq` ↔ `Hash`** must agree: equal values MUST hash equal.
- **`Ord` / `PartialOrd`** must be a consistent total/partial order (no intransitive or non-reflexive comparisons).
- **`PartialEq`** must be symmetric and transitive.
- **`From` is infallible; `TryFrom` is fallible** — do not implement an infallible `From` for a conversion that can fail.

## 6. Traits & Generics

- Design **small, coherent traits**; respect the **orphan rule** (implement a trait for a type only when you own one of them).
- Prefer generics with bounds / `impl Trait` for **static dispatch** (monomorphized, zero-cost) by default; reach for `dyn Trait` only for heterogeneous collections or to curb code size.

## 7. Lifetimes

- **Elide** when the compiler can infer; **annotate** for clarity where it aids the reader.
- Avoid gratuitous `'static` — it is a constraint, not a default; justify it when used.

## 8. Naming

- `snake_case` for items (functions, variables, modules), `PascalCase` for types/traits, `SCREAMING_SNAKE_CASE` for consts/statics.

## 9. Iterators & Idiomatic Constructs

- **Iterator chains over manual index loops** — express transformation declaratively.
- **Pattern matching is exhaustive**; a catch-all `_` is deliberate, never a lazy shortcut.
- **Clear public API surface** — expose the minimum; use `pub(crate)` / module privacy to keep internals internal.

## 10. Allocations & Micro-Performance

Language-level allocation hygiene (distinct from algorithmic complexity):

- Avoid unnecessary allocations and clones; prefer `&str` over `String`, a slice over an owned `Vec` where ownership is not required.
- Pre-size with `Vec::with_capacity` when the length is known; avoid avoidable boxing.
- These matter most in hot paths — a measured `criterion` number beats a guess before trading safety for speed.

## 11. Concurrency

- Thread-safe types are `Send + Sync`; prefer **message passing (channels) over shared mutable state**.
- Reach for `Arc<Mutex<T>>` / `Arc<RwLock<T>>` only when shared mutability is genuinely required.

## 12. Unsafe (the principle)

- **Avoid `unsafe`.** When it is unavoidable: uphold and **document the safety invariants** (`# Safety`), and **encapsulate it behind a safe API** so no safe caller can trigger undefined behavior.
- (The reviewer verifies this as a soundness question — that method, and the specific UB checks, live in the `rust-reviewer`.)

## 13. Async Hazards

When async is in play:

- **Cancellation safety** — use `tokio::select!` deliberately; keep cleanup cancel-safe.
- **Structured concurrency** — `JoinSet`; bound spawning with semaphores / bounded channels; always join or abort spawned tasks.
- **Backpressure & timeouts** — bounded `mpsc`; apply `tokio::time::timeout` to **ALL** I/O.
- **Never block the executor** — offload blocking or CPU-bound work with `tokio::task::spawn_blocking` (or `rayon`); never `std::thread::sleep` or run sync I/O on an async task.
- **No lock guard across `.await`** — never hold a `std::sync::Mutex` / `RefCell` guard across an await point (it yields a `!Send` future or deadlocks); use `tokio::sync::Mutex`, or drop the guard first.
- **Spawn bounds** — `tokio::spawn` requires `Send + 'static`; a non-`Send` value held across `.await`, or a borrowed capture, won't spawn.
- **Await every future** — a future that is never `.await`ed is a silent no-op.
- **Runtime consistency** — don't mix runtimes (Tokio / async-std / smol); document the runtime requirement.

## 14. Lints, Formatting & Tooling Discipline

- Good Rust compiles clean under `#![deny(clippy::all, clippy::pedantic)]` with **zero warnings** in production code.
- `#[allow(clippy::...)]` is used only with a written justification.
- Code is `rustfmt`-clean. A defect is clippy warnings, `cargo fmt --check` drift, or an unjustified `#[allow]`.

---
*Standard Version: 1.0 — the shared Rust rubric. Built to by rust-developer (via build-core); reviewed against by rust-reviewer (which owns correctness detection, the unsafe soundness method, and scoring).*
