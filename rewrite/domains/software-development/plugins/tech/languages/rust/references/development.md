# Rust: development

## Defaults when nothing given says otherwise

- **A new dependency goes into `Cargo.toml` only;** its download is left to the human: record it, and a gate step that needs it doesn't run.
- **The async runtime** is Tokio.
- **The web framework** is Axum.

## Edge cases

- **`unsafe` or FFI is needed:** follow the `unsafe` rules, and record it.

## Verification gate

Its tools are `cargo` and the `rustfmt` and `clippy` components.

Run `cargo check`, `cargo clippy` and `cargo test` with `--offline`. A step that would need a download doesn't run, as for a missing tool. No `cargo`, `rustfmt` or `clippy`: each step that needs it doesn't run, with what is missing and its install hint as the reason. A missing component's hint is `rustup component add clippy rustfmt`.

The baseline is steps 1, 2 and 3: each warning, error and finding with its count; a new file's baseline is empty. After the change, run every step and compare steps 1, 2 and 3 against the baseline.

**Name each issue by its lint name** (`clippy::<lint>`): a finding with no id can't be matched against the baseline the gate compares to.

1. The formatting check (gate `format`): `cargo fmt --check`.
2. The compile check (gate `typecheck`): `cargo check --all-targets --offline`.
3. The lint check (gate `lint`): `cargo clippy --all-targets --all-features --offline -- -D warnings -D clippy::pedantic`.
4. The existing tests (gate `test`): `cargo test --offline`.

A build (`cargo build --release`) is not a per-change gate.

## Self-check before reporting

1. The toolchain was settled in the Toolchain order, and library or binary read from `Cargo.toml`.
2. No `unwrap`, `expect` or `panic!` in library code.
3. No lossy `as` cast at a boundary.
4. Every `unsafe` block sits behind a safe API, with its `# Safety` invariants written.
5. No `std::sync::Mutex` or `RefCell` guard is held across `.await`.
