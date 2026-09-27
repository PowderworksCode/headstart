# headstart

Start dependent crates before their dependencies finish type-checking.

In a `cargo check` build, each crate waits for every crate it depends on
to be fully checked, function bodies included. It doesn't need those
bodies: it compiles against the dependency's interface, the metadata in
its `.rmeta` file. Headstart makes rustc write that metadata as soon as
the interface is checked, and makes cargo start dependents on it. Each
crate's bodies are checked while the crates downstream are already
compiling.

If a body has an error, the build still fails with that error, and prints
exactly what it prints today. Cargo reports a crate's output only once all
its dependencies have finished cleanly, and drops it if one fails. The
only cost is work done downstream that gets thrown away.

## Pieces

- **rustc, `-Zearly-metadata`** ([patches/rustc](patches/rustc)): splits
  type-checking into interfaces and bodies, and writes the metadata in
  between.
- **cargo, `CARGO_HEADSTART=1`** ([patches/cargo](patches/cargo)):
  pipelines `cargo check` the way cargo already pipelines `cargo build`,
  and passes `-Zearly-metadata` to crates that have dependents.

How it works, what the early metadata leaves out, and the risks:
[docs/design.md](docs/design.md). Measurements:
[docs/results.md](docs/results.md).

## Try it

```sh
scripts/setup.sh    # check out rustc + cargo, apply the patches, build both
```

Then, in any Rust project:

```sh
RUSTC=/path/to/headstart/rustc/build/host/stage1/bin/rustc \
CARGO_HEADSTART=1 \
  /path/to/headstart/cargo/target/release/cargo check
```

With `CARGO_HEADSTART` unset, the patched cargo behaves like upstream, so
the same binaries give a fair baseline.

`tests/smoke` is a two-crate workspace that shows the effect. Its `slow`
library takes several seconds to check, almost all of it in function
bodies. With headstart on, `app` starts about 0.2 s in instead of
waiting for `slow` to finish.

`scripts/check-errors.sh` checks the claim about errors on `tests/errors`. It builds
three scenarios (a clean build, an error in a dependency, an error in the
binary) with headstart off and on. It then compares the human-readable
output, the JSON output and the exit status.

`scripts/check-incremental.sh` does the same across a sequence of
incremental edits. The steps include adding an `impl Fn` a dependent
calls, and breaking and then fixing an interface. It also compares the
final state against a clean build.

## Benchmarks

```sh
scripts/bench.sh -n 5 path/to/project ...
```

This times clean `cargo check` builds, alternating headstart off and on,
and prints the medians. `scripts/bench-mem.sh` measures peak memory the
same way. `scripts/bench-incremental.sh` times incremental rechecks after
editing one function body. `scripts/log-rustc` records when each rustc run
started and ended, so you can see the schedule. The rustc-perf benchmarks
are under `rustc/src/tools/rustc-perf/collector/compile-benchmarks`
(`git -C rustc submodule update --init --depth 1 src/tools/rustc-perf`).
