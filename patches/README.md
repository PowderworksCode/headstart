# The patches

Two commit series, written with `git format-patch`, one per repository.
`scripts/setup.sh` applies them, in order, to the pinned commits (the
`rustc` and `cargo` submodules) as working-tree changes. To get them as
commits instead, for a pull request:

```sh
git clone https://github.com/rust-lang/rust && cd rust
git checkout -b early-metadata 6006fd03947bd7b04ae5cb5f7f9bb66b44dc8c6e
git am /path/to/headstart/patches/rustc/*.patch
```

The same with rust-lang/cargo at `4f3fb2428282fb2467c4bb5be0163d2f42a31491`
and `patches/cargo`. On a newer upstream, `git am -3` resolves what it
can.

Every commit builds on its own, and passes the repository's own checks:
`./x fmt --check`, `./x test tidy`, and `cargo fmt --check`.

## rust-lang/rust

| | commit | what it does |
|---|---|---|
| 1 | Don't compute the reachable set for metadata without codegen | Independent of the rest, and useful on its own: `cargo check` stops computing a set only code generation reads. The metadata doesn't change. Can go first, as its own PR. |
| 2 | rustc_metadata: encode each definition and its MIR in helpers | A refactor with no behavior change, mostly indentation; makes commit 4 readable. |
| 3 | Add an `analysis_interfaces` query | Splits `analysis` at the point early metadata is written. No behavior change, except the `type_check_crate` timer becomes two. |
| 4 | Add `-Zearly-metadata`: write metadata once item interfaces are checked | The writing side: the early file, the shared crate hash, and the output locks dependents wait on. Adds two UI tests in `tests/ui/rmeta/`. |
| 5 | Load early metadata, and swap in full metadata before codegen | The reading side: the locator, the swap to full metadata, and waiting for full metadata and rlibs on their locks. Adds `tests/run-make/early-metadata`. |
| 6 | Add `-Zearly-metadata-verify` | The checks the benchmark sweeps rely on. |

Commits 2 to 6 need a compiler MCP: `-Zearly-metadata` is a new unstable
flag, and it extends `--json=artifacts` with three notification kinds
(`early-metadata`, `wait-metadata`, `resume`).

Tests:
- `./x test tests/run-make/early-metadata tests/ui/rmeta`.
- rustc's UI suite (`./x test tests/ui`), which runs with the flag off and
  checks that nothing else changed.
- The UI suite with the flag on for every test:

  ```sh
  ./x test tests/ui --force-rerun --compiletest-rustc-args "-Zearly-metadata -Zearly-metadata-verify"
  ```

  Every test passes except four whose expected output depends on when
  bodies are checked: three report the same errors in another order, and
  one prints a different query stack for a deliberate ICE.

## rust-lang/cargo

| | commit | what it does |
|---|---|---|
| 1 | Add `-Zheadstart`: start units on dependencies' early metadata | The flag, its documentation in `unstable.md`, passing `-Zearly-metadata`, and scheduling units on the `early-metadata` notification. Linked units' freshness still looks at their dependencies' rlibs. |
| 2 | headstart: a paused compilation gives up its job slot | Pause accounting, on `wait-metadata` and `resume`. |
| 3 | headstart: report a unit's output only once its dependencies succeed | Provisional output, so a failing build reports what it would without the flag. |

The tests are in `tests/testsuite/headstart.rs`. All but one need a
nightly rustc with `-Zearly-metadata`, so they can only run once the
rustc side has landed (and rust-lang/rust's CI disables nightly cargo
tests anyway). Until then, run them against a patched rustc:

```sh
S=/path/to/headstart/rustc/build/host/stage1/bin
# The test macro decides "nightly" from the `rustc` on PATH at compile time.
RUSTC=$(rustup which rustc) PATH=$S:$PATH cargo test --test testsuite --no-run
PATH=$S:$PATH target/debug/deps/testsuite-* headstart
```
