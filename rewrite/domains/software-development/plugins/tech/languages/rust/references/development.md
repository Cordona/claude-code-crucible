# Rust: development

Apply after `SKILL.md`'s rules, before writing any Rust.

## Reporting

`standard-code-development-report` sets each item's shape.

- **The toolchain found** (edition, MSRV, `rustc` version, async runtime) -> the report's `toolchain`, because the reviewer judges the code against the edition and MSRV it names.
- **Each Verification gate command and its result** -> the report's `verification`, one item per command, with each warning that predates your change in `note` with its count, and a step you didn't run as `not_run` with its reason in `note`, never left out, because a gate result the report doesn't show reads as a gate that never ran.

## Defaults when the first message is silent

- **The toolchain** comes from `SKILL.md`'s Toolchain order.
- **The async runtime** is Tokio.
- **The web framework** is Axum.
- **The error crates** follow the crate kind, as `SKILL.md`'s Errors and panics sets.

## Edge cases

- **`unsafe` or FFI is needed:** follow `SKILL.md`'s `unsafe` rules, and record it in the report's `decisions`.

## Verification gate

Run it on every change, before reporting done. Its tools are `cargo` and the `rustfmt` and `clippy` components.

The gate writes only Cargo's build output under the crate's `target/`. A missing component: record its step `not_run` with the hint `rustup component add clippy rustfmt` as its note, a hint to record, not a command to run.

1. `cargo fmt --check`: the formatting check.
2. `cargo check --all-targets`: the compile check.
3. `cargo clippy --all-targets --all-features -- -D warnings -D clippy::pedantic`, with no new warnings: run it before and after your change. The step passes when your change adds no warning.
4. `cargo test`: the existing tests.

`cargo build --release` is not a per-change gate.

## Self-check before reporting

1. The toolchain was settled in `SKILL.md`'s order, and library or binary read from `Cargo.toml`.
2. No `unwrap`, `expect` or `panic!` in library code.
3. No lossy `as` cast at a boundary.
4. Every `unsafe` block sits behind a safe API, with its `# Safety` invariants written.
5. No `std::sync::Mutex` or `RefCell` guard is held across `.await`.
6. Each gate step ran, or is `not_run` with its reason.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
