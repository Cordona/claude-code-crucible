# Rust: development

Apply after `SKILL.md`'s rules, before writing any Rust.

## Reporting

`standard-code-development-report`, which `code-developer` preloads, sets each item's shape; do not load it again.

- **The toolchain found** (edition, MSRV, `rustc` version, async runtime) -> the report's `toolchain`, because the reviewer judges the code against the edition and MSRV it names.
- **Each Verification gate command and its result** -> the report's `verification`, one item per command, its `gate` value as its step names it, because a gate result the report doesn't show reads as a gate that never ran.
- **Each warning, error or finding that predates your change** goes in its command's `note`, with its count.
- **A step you didn't run** is `not_run`, with its reason in `note`, or `narrowed` when `TASK` narrowed it; never leave it out.

## Defaults when the first message is silent

- **The toolchain** comes from `SKILL.md`'s Toolchain order.
- **The async runtime** is Tokio.
- **The web framework** is Axum.
- **The error crates** follow the crate kind, as `SKILL.md`'s Errors and panics sets.

## Edge cases

- **`unsafe` or FFI is needed:** follow `SKILL.md`'s `unsafe` rules, and record it in the report's `decisions`.
- **FFI would need `panic = "abort"`:** make no project-wide change (the `Cargo.toml` profile) unless the task covers it; record the change the code needs in the report's `noticed`.

## Verification gate

Take the baseline before your first edit; run the full gate on every change, before reporting done. Its tools are `cargo` and the `rustfmt` and `clippy` components.

The gate writes only Cargo's output under the crate's `target/` and what the tests write.

The gate fetches and installs nothing: run `cargo check`, `cargo clippy` and `cargo test` with `--offline`. A step that would need a download is `not_run`, as for a missing tool. No `cargo`, `rustfmt` or `clippy`: record each step that needs it `not_run`, with a note naming what is missing and its install hint: a hint to record, never a command to run. A missing component's hint is `rustup component add clippy rustfmt`.

Before your first edit, run steps 1, 2 and 3 and record each warning, error and finding with its count as the baseline; a new file's baseline is empty. After the change, run every step and compare steps 1, 2 and 3 against the baseline.

1. The formatting check (gate `format`): `cargo fmt --check`. It passes when your change adds nothing to the baseline.
2. The compile check (gate `typecheck`): `cargo check --all-targets --offline`. It passes when your change adds nothing to the baseline.
3. The lint check (gate `lint`): `cargo clippy --all-targets --all-features --offline -- -D warnings -D clippy::pedantic`. It passes when your change adds nothing to the baseline.
4. The existing tests (gate `test`): `cargo test --offline`.

A build (`cargo build --release`) is not a per-change gate.

## Self-check before reporting

1. The toolchain was settled in `SKILL.md`'s order, and library or binary read from `Cargo.toml`.
2. No `unwrap`, `expect` or `panic!` in library code.
3. No lossy `as` cast at a boundary.
4. Every `unsafe` block sits behind a safe API, with its `# Safety` invariants written.
5. No `std::sync::Mutex` or `RefCell` guard is held across `.await`.
6. Each gate step ran, or is `not_run` or `narrowed` with its reason.
7. Each item `## Reporting` names is in the report.

A failed item: fix it, then run the check again.
