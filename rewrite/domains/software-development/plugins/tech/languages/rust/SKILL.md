---
name: language-rust
description: "Rust rules: toolchain, errors, panics, casts, std traits, `unsafe`, async, ownership, clippy, plus the developer's verification gate. Use when writing or reviewing Rust in a Cargo crate. A language plugin. Its gate writes only Cargo's `target/` and what the tests write; needs `cargo`, `rustfmt` and `clippy`. Not for Rust driven only from another file (a Dockerfile `RUN`, a CI step), or rules every language shares (`code-developer`, standard plugins)."
disable-model-invocation: true
user-invocable: false
metadata:
  label: Rust
---

# Language: Rust

The rules that are specific to Rust. Every role receives this file in its first message. A developer then receives `references/development.md` right after it: what to report, the defaults, the edge cases and the verification gate. A reviewer receives `references/review.md` right after it instead: how to judge a finding and how to grade it.

## Scope

- **In:** Rust crates and workspaces built with Cargo: libraries, binaries, CLIs, services and async applications.
- **In:** code on a web framework with no plugin of its own, such as Axum.
- **Out:** Rust driven only from another file, such as a Dockerfile `RUN cargo build` line or a CI step.

## Toolchain

Settle it before writing a line. Take each fact from the first source below that sets it:

1. `rust-toolchain.toml`, or `rust-toolchain`.
2. `Cargo.toml`'s `rust-version` and `edition`; the workspace's `Cargo.toml` when the crate inherits them.
3. What the project's own docs on its Rust code say, where the task's context lists them.
4. Otherwise the 2024 edition on the latest stable `rustc` (see Version ledger).

Read whether the crate is a library or a binary from `Cargo.toml` (`[lib]`, `[[bin]]`) or from `src/lib.rs` and `src/main.rs`: the error and panic rules differ by it.

## Errors and panics

- **Fallible work returns `Result<T, E>`,** propagated with `?` rather than `match` boilerplate.
- **Error crates follow the crate kind:** `thiserror` error types in a library; `anyhow` in a binary or CLI, or `color-eyre` where the project already uses it.
- **No `unwrap()`, `expect()` or `panic!()` in library code:** return a `Result`. Test code may `unwrap`.
- **A dropped fallible result is a defect:** `let _ =` on a fallible call, an ignored `#[must_use]`, a discarded error.
- **Unchecked indexing is panic surface,** as `unwrap` is.

## Arithmetic and casts

- **Integer overflow panics in debug and wraps silently in release:** pick `checked_*`, `saturating_*` or `wrapping_*` deliberately for any value that can pass its type's bounds.
- **No lossy `as` cast at a boundary** (`usize as u32`, `i64 as i32`, float to int): use `TryFrom` or `try_into`, so an out-of-range value is an error, not silent corruption.
- **An overflow with a security consequence** (fraud, over-allocation, an out-of-bounds index) is a correctness defect with a security harm, not only arithmetic.

## std trait contracts

A broken contract silently corrupts `HashMap`, `BTreeMap` and sorts, whatever the style:

- **`Eq` and `Hash` agree:** equal values hash equal.
- **`Ord` and `PartialOrd` are consistent** total or partial orders: no intransitive or non-reflexive comparison.
- **`PartialEq` is symmetric and transitive.**
- **`From` is infallible, `TryFrom` fallible:** never an infallible `From` for a conversion that can fail.

## `unsafe`

- **Avoid `unsafe`.** Where it is unavoidable, uphold and document its invariants in a `# Safety` section, and wrap it in a safe API: no safe caller can reach undefined behaviour (UB).
- **FFI: a panic crossing an `extern "C"` boundary is UB:** wrap the exported function's body in `catch_unwind`; set `panic = "abort"` instead only when the whole binary may abort on any panic and the task covers that `Cargo.toml` profile change.

## Concurrency and async

- **Thread-safe types are `Send + Sync`.**
- **Prefer message passing over channels to shared mutable state.**
- **`Arc<Mutex<T>>` or `Arc<RwLock<T>>` only when shared mutability is needed.**

When async is in play:

- **Cancel safety:** use `tokio::select!` deliberately, and keep cleanup cancel-safe.
- **Structured concurrency:** use `JoinSet`.
- **Bound spawning** with a semaphore or a bounded channel.
- **Join or abort every spawned task.**
- **Backpressure and timeouts:** bounded `mpsc` channels, and `tokio::time::timeout` on all I/O.
- **Never block the executor:** offload blocking or CPU-bound work with `tokio::task::spawn_blocking` or `rayon`; no `std::thread::sleep` or sync I/O on an async task.
- **No `std::sync::Mutex` or `RefCell` guard across `.await`:** it yields a `!Send` future or deadlocks. Use `tokio::sync::Mutex`, or drop the guard first.
- **`tokio::spawn` needs `Send + 'static`:** a non-`Send` value held across `.await`, or a borrowed capture, won't spawn.
- **Await every future:** one never `.await`ed is a silent no-op.
- **One runtime:** don't mix Tokio, async-std and smol, and document the runtime the crate needs.

## Ownership, borrowing and allocation

- **Borrow over clone:** `&T`, `&str` over `String`, `&[T]` over `Vec<T>`.
- **`Cow<'a, T>` for conditional ownership:** borrow in the common case, own only when mutation needs it.
- **Interior mutability** (`RefCell`, `Cell`, `Mutex`) is chosen deliberately, not by habit.
- **A `.clone()` to quiet the borrow checker is a design smell:** fighting the checker again and again signals a design problem.
- **Pre-size with `Vec::with_capacity`** when the length is known.
- **No needless boxing.**
- **Fuse iterator chains** rather than collecting intermediates.
- **Allocation matters most on hot paths:** measure with `criterion` before trading safety for speed.

## Types, traits, lifetimes and naming

- **Newtypes for domain concepts** (`UserId(Uuid)`), not bare primitives.
- **Enums for state machines and closed sets.**
- **`Option<T>`, never null or a sentinel.**
- **Make illegal states unrepresentable,** and validate at the boundary with types (newtypes, type-state).
- **Small, coherent traits,** within the orphan rule: implement a trait for a type only when the crate owns one of them.
- **Static dispatch by default** (bounded generics, `impl Trait`); `dyn Trait` only for a heterogeneous collection or to curb code size.
- **Elide lifetimes** where the compiler infers them: a spelled-out elidable lifetime is noise `clippy::needless_lifetimes` flags; annotate one only where it shows which input the output borrows from.
- **No gratuitous `'static`:** it is a constraint, not a default; justify each one.
- **Iterator chains over manual index loops:** an index loop brings the off-by-one and panic-on-index surface an iterator rules out.
- **`match` is exhaustive;** a catch-all `_` only on purpose, since it silently swallows future variants.
- **The smallest `pub` surface:** `pub(crate)` and module privacy keep internals internal; no dead `pub` items.

## Rust mechanisms for the shared standards

- **Queries:** parameterized through `sqlx::query!` or Diesel.
- **Secrets in memory:** `secrecy` and `zeroize`.
- **Supply chain:** `cargo-audit`, and pinned dependencies.
- **Tracing:** `tracing` spans with structured fields, through `tracing-subscriber`, with context carried across `.await`.
- **Docs:** `///` on a public item only when its signature can't state a constraint, a failure condition or behaviour beyond it, with a doc-test where it has an example.
- **Persistence:**
  - explicit `sqlx` or Diesel transactions;
  - `SELECT … FOR UPDATE` or a version column against lost updates;
  - a bounded `LIMIT` with keyset pagination;
  - `sqlx migrate` in expand-contract steps;
  - a pooled connection's lifecycle left to `sqlx`'s or Diesel's own RAII drop guards.

## Lints

- **Compile with no new warning:** treat each one your change adds as a gate failure. Old ones in an existing project would otherwise fail every change.
- **Clippy (`clippy::all`, `clippy::pedantic`) with no new warning:** treat each one your change adds as a gate failure. Old ones in an existing project would otherwise fail every change.
- **Name each issue by its lint name** (`clippy::<lint>`): a finding with no id can't be matched against the baseline the gate compares to.
- **Every `#[allow(…)]` and `#[expect(…)]`, rustc's and Clippy's alike, carries its written reason:** a reasoned one on a line complies, an unexplained one is a defect, and a rule turned off or down in the project's lint config is a defect too.

## Version ledger

| Fact | Value | Last verified |
|---|---|---|
| Default edition (Toolchain step 4) | 2024 | 2026-10-24, `cargo new` (cargo 1.92.0), macOS |
| Latest stable `rustc` | 1.99.1, released 2026-10-13 | 2026-10-24, `rustup check`, macOS |
