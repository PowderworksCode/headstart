# Results

Timings come from clean builds taken with `scripts/bench.sh`, of the
rustc-perf benchmarks (in
`rustc/src/tools/rustc-perf/collector/compile-benchmarks`) and of 13 real
projects (`scripts/real-projects.sh`). Each run alternates headstart off
and on, using the same patched rustc and cargo. With headstart off, both
behave like upstream. Tables give medians. Memory and incremental
numbers come from `scripts/bench-mem.sh` and
`scripts/bench-incremental.sh`.

The first sections cover the current version: early metadata as a
separate file, used by both `cargo check` and `cargo build`, on the
rustc-perf benchmarks and on 13 real projects (rust-analyzer, zed, bevy,
lemmy and others). The later sections are measurements of the first,
check-only version. They're kept for the error-delay, memory, clippy,
rustdoc and incremental numbers, which haven't been measured again since;
their timing tables are superseded by the current ones.

## Correctness (current version)

- **Benchmark sweeps** (`scripts/sweep.sh`).
  - **What they build:** all 53 compile benchmarks (not counting the
    `-new-solver`, `-nll`, `-tiny` and `-threads4` variants of others;
    about 20 are a single crate, which headstart can't help but mustn't
    break), with headstart
    off and on, on Linux with 16 jobs, with `-Zearly-metadata-verify`.
  - **Six sweeps:** `cargo check` and `cargo build`, each in debug, in
    release (`-r`), and in debug with `-Zthreads=8` (`-t`).
  - **Result:** in every sweep, 52 benchmarks pass in both modes with
    identical diagnostics, and verify reports nothing.
  - stm32f4 fails in both modes because it needs a device feature; its
    build-script panic messages differ only in the thread ID.
- **Real projects.** 13 projects, 312 builds, all succeeded with
  identical diagnostics. The one exception is noise from the parallel
  front end itself (see "Real projects").
- **`scripts/check-swap.sh`** makes a library start on its dependency's
  early metadata and swap in the full metadata while paused. At
  opt-levels 0, 1, 2, 3 and s, the program built from it prints the same
  as one built from full metadata.
- **Test suites.**
  - Both run with the patches applied and headstart off, their default,
    so they check that the patches change nothing else. They don't
    exercise early metadata itself.
  - rustc's UI suite: 22129 passed, 0 failed, 259 ignored, on Linux.
  - cargo's test suite: 4034 passed. The single failure,
    `aaa_trigger_cross_compile_disabled_check`, only flags that there's no
    cross-compilation target installed.
- **Errors.** `scripts/check-errors.sh` runs three scenarios on
  `tests/errors`: a clean build, an error in a dependency's body, and an
  error in the binary. It runs each with `cargo check` and `cargo build`,
  in human and JSON formats, with headstart off and on. Diagnostics and
  exit status are identical, and so is what the built binary prints.
  What can differ is output that already depends on timing:
  - progress lines (`Checking`, `Compiling`, `Finished`, "waiting for
    other jobs");
  - the order of JSON messages across crates, which cargo doesn't
    guarantee, and headstart holds a crate's messages until its
    dependencies finish;
  - lock-wait messages.
- **Incremental.** `scripts/check-incremental.sh check` and
  `scripts/check-incremental.sh build` run ten edit steps each. Every step
  matches headstart-off, and the final state matches a clean build.

The sweeps found two bugs in the swap to full metadata, both fixed:

- **A stale type cache.** rustc caches decoded types by their position
  in a crate's metadata. After the swap, positions in the full file
  collided with cached ones from the early file. This crashed
  cargo-0.87.1 and large-workspace.
- **Stale-looking full metadata.** Incremental compilation reused a full
  `.rmeta` by hard-linking it, which kept its old modification time, so
  it looked older than this compilation's early metadata. Writing early
  metadata now deletes the crate's stale full metadata and rlib first,
  so a full file next to early metadata is never an older one.

## Timing, current version: Linux, AMD EPYC 9554P, 16 jobs, 5 runs

These were measured before the three fixes under "Bugs found by the real
projects". Two of them apply only with optimization or `-Zthreads`. The
third skips work in `cargo check` that was never read, so it can only
make the check column faster; it wasn't re-timed.

The 21 are a fixed set of multi-crate benchmarks, kept the same across
rounds so that versions compare. All 53 benchmarks are in the sweeps.

Build and check were measured back to back in one session, alternating
headstart off and on. Another user's two long-running compilations kept
the VM's load average at 3–5 throughout. Off and on runs share that
load equally, so the savings compare, but absolute times are a little
higher than on an idle machine. All 420 builds succeeded.

"Previous" is the saving measured for the version before this one, on
an idle VM (commit 0a09236). Since then:

- binaries, tests, proc macros and build scripts also start on early
  metadata, and wait for rlibs only before linking;
- a resumed compilation no longer waits for a free job slot (see
  [design.md](design.md#pausing)). Measured with `scripts/critical-path.py`,
  resumed compilations on the critical path had spent seconds waiting
  for a slot while work started in their place held it.

| project | build today | build headstart | saved | previous | check today | check headstart | saved | previous |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| ripgrep-14.1.1 | 15.01 s | 9.88 s | 34% | 23% | 10.15 s | 5.53 s | 46% | 47% |
| serde_derive-1.0.219 | 8.33 s | 5.23 s | 37% | 9% | 5.62 s | 3.61 s | 36% | 35% |
| piston-image | 8.33 s | 5.72 s | 31% | 32% | 6.11 s | 3.99 s | 35% | 36% |
| eza-0.21.2 | 33.36 s | 21.79 s | 35% | 19% | 27.03 s | 18.94 s | 30% | 30% |
| clap_derive-4.5.32 | 7.89 s | 5.73 s | 27% | 8% | 5.83 s | 4.06 s | 30% | 31% |
| unicode-normalization-0.1.24 | 2.13 s | 1.62 s | 24% | 24% | 1.90 s | 1.32 s | 31% | 31% |
| tt-muncher | 2.30 s | 1.56 s | 32% | 10% | 1.79 s | 1.29 s | 28% | 28% |
| image-0.25.6 | 26.07 s | 20.35 s | 22% | 18% | 19.32 s | 13.94 s | 28% | 23% |
| html5ever | 16.93 s | 12.35 s | 27% | 12% | 16.61 s | 12.18 s | 27% | 13% |
| hyper-1.6.0 | 2.87 s | 2.19 s | 24% | 18% | 2.41 s | 1.84 s | 24% | 22% |
| nalgebra-0.33.0 | 24.11 s | 18.46 s | 23% | 21% | 22.57 s | 17.61 s | 22% | 20% |
| regex-automata-0.4.8 | 9.56 s | 7.50 s | 22% | 18% | 6.73 s | 5.28 s | 22% | 21% |
| wg-grammar | 10.51 s | 8.25 s | 22% | 19% | 9.91 s | 7.98 s | 19% | 15% |
| cargo-0.87.1 | 95.71 s | 83.35 s | 13% | 11% | 51.17 s | 41.48 s | 19% | 22% |
| cargo | 30.04 s | 25.26 s | 16% | 6% | 20.76 s | 17.00 s | 18% | 18% |
| html5ever-0.31.0 | 8.30 s | 6.84 s | 18% | 13% | 7.62 s | 6.47 s | 15% | 11% |
| projection-caching | 11.63 s | 10.11 s | 13% | 6% | 11.18 s | 9.50 s | 15% | 9% |
| syn-2.0.101 | 4.93 s | 4.26 s | 14% | 15% | 3.51 s | 3.06 s | 13% | 14% |
| diesel-2.2.10 | 40.44 s | 36.78 s | 9% | 7% | 38.18 s | 34.74 s | 9% | 7% |
| cranelift-codegen-0.119.0 | 28.86 s | 26.45 s | 8% | 7% | 19.99 s | 18.17 s | 9% | 8% |
| encoding | 1.48 s | 1.39 s | 6% | 6% | 1.10 s | 1.04 s | 5% | 8% |

- **`cargo build` gains most.** Proc-macro chains (serde_derive,
  clap_derive) and binaries at the end of the graph (eza, ripgrep,
  html5ever) no longer wait for every rlib to be finished before they
  start.
- **`cargo check`** changes less, since check units already started on
  early metadata. The largest gains (html5ever, projection-caching,
  image) come from binaries starting early and from the pause fix.
- **The slot-waiting variant in between** (commit 8c1b8a4) made cargo-0.87.1 8% slower to build and 19% slower to
  check: cargo held back new work until a resumed compilation got a
  slot, while it competed for slots with libgit2's C build. Resuming
  without a slot fixed that.

## With the parallel front end, current version (`RUSTFLAGS=-Zthreads=8`)

The same 21 benchmarks, with `-Zthreads=8` on both sides, 5 runs each,
after the fixes described under "Bugs found by the real projects". The
load average was about 5 when each part started.

| project | build today | build headstart | saved | check today | check headstart | saved |
|---|--:|--:|--:|--:|--:|--:|
| unicode-normalization-0.1.24 | 1.27 s | 0.96 s | 24% | 1.15 s | 0.78 s | 32% |
| ripgrep-14.1.1 | 8.83 s | 7.10 s | 20% | 4.63 s | 3.45 s | 25% |
| clap_derive-4.5.32 | 3.88 s | 2.86 s | 26% | 2.70 s | 2.08 s | 23% |
| projection-caching | 5.32 s | 4.35 s | 18% | 5.31 s | 4.11 s | 23% |
| hyper-1.6.0 | 1.38 s | 1.18 s | 14% | 1.23 s | 0.98 s | 20% |
| html5ever | 8.67 s | 7.04 s | 19% | 8.57 s | 7.15 s | 17% |
| encoding | 0.94 s | 0.94 s | 0% | 0.83 s | 0.70 s | 16% |
| serde_derive-1.0.219 | 4.28 s | 3.59 s | 16% | 2.62 s | 2.20 s | 16% |
| image-0.25.6 | 15.61 s | 14.26 s | 9% | 9.90 s | 8.37 s | 15% |
| nalgebra-0.33.0 | 8.64 s | 7.59 s | 12% | 8.15 s | 7.13 s | 13% |
| tt-muncher | 1.85 s | 1.56 s | 16% | 1.44 s | 1.29 s | 10% |
| wg-grammar | 5.82 s | 5.24 s | 10% | 5.83 s | 5.26 s | 10% |
| cargo | 19.39 s | 16.89 s | 13% | 14.11 s | 12.81 s | 9% |
| syn-2.0.101 | 2.41 s | 2.29 s | 5% | 1.76 s | 1.61 s | 9% |
| html5ever-0.31.0 | 4.38 s | 3.93 s | 10% | 4.16 s | 3.83 s | 8% |
| piston-image | 4.54 s | 4.14 s | 9% | 3.20 s | 2.93 s | 8% |
| diesel-2.2.10 | 14.77 s | 13.80 s | 7% | 14.97 s | 13.93 s | 7% |
| regex-automata-0.4.8 | 4.00 s | 3.68 s | 8% | 2.58 s | 2.41 s | 7% |
| eza-0.21.2 | 19.43 s | 18.67 s | 4% | 16.20 s | 15.22 s | 6% |
| cranelift-codegen-0.119.0 | 15.03 s | 14.70 s | 2% | 10.30 s | 10.01 s | 3% |
| cargo-0.87.1 | 57.00 s | 54.50 s | 4% | 33.04 s | 32.86 s | 1% |

- **Nothing is slower.** Headstart saves 14–32% on chain-shaped builds
  (ripgrep, clap_derive, unicode-normalization, projection-caching,
  hyper), and a few percent on the large ones, where the parallel front
  end already fills the cores.
- **regex-automata** was slower in every earlier measurement with
  `-Zthreads` (up to 7%); it's 7–8% faster now. Like zola, it has large static tables that were evaluated
  on one thread before the early write.
- **encoding's** 16% in check is 0.13 s on a sub-second build.

## Real projects: Linux, AMD EPYC 9554P, 16 jobs, 3 runs

Thirteen open-source projects, cloned at the commits listed in
`scripts/real-projects.sh`, which reproduces this set:

```sh
scripts/bench.sh -n 3 -c check $(scripts/real-projects.sh ~/hs-real)
```

- **Notoriously slow builds:** rust-analyzer, bevy, nushell, wasmtime,
  typst, helix, polars, zed.
- **Web apps and services:** lemmy (actix, diesel/postgres), vaultwarden
  (rocket, diesel/sqlite), atuin (axum, sqlx), zola, lldap.
- **Setup:** all with the default dev profile, from clean.
  - Several projects pin a toolchain in `rust-toolchain.toml`. Every
    build here uses the patched rustc, so the pins don't apply.
  - meilisearch was dropped: its current code doesn't compile with
    this rustc, with or without headstart.
- **Load:** another user's jobs kept the VM's load average at 3–5
  before each pass started. Off and on runs alternate, so both share it.
- **Result:** all 312 builds succeeded, with identical diagnostics in both
  modes, except lemmy under `-Zthreads` (below).

| project | check today | check headstart | saved | build today | build headstart | saved |
|---|--:|--:|--:|--:|--:|--:|
| rust-analyzer | 90.1 s | 41.5 s | 54% | 137.9 s | 79.9 s | 42% |
| polars | 172.4 s | 87.4 s | 49% | 341.2 s | 241.4 s | 29% |
| wasmtime | 150.5 s | 79.9 s | 47% | 244.6 s | 155.8 s | 36% |
| helix | 44.2 s | 30.5 s | 31% | 78.0 s | 64.4 s | 17% |
| bevy | 120.9 s | 85.3 s | 29% | 195.8 s | 136.9 s | 30% |
| zed | 280.0 s | 204.3 s | 27% | 425.1 s | 318.2 s | 25% |
| lemmy | 448.8 s | 330.8 s | 26% | 532.3 s | 371.6 s | 30% |
| typst | 86.0 s | 63.2 s | 26% | 142.2 s | 123.4 s | 13% |
| lldap | 69.0 s | 56.6 s | 18% | 100.8 s | 77.5 s | 23% |
| atuin | 125.2 s | 109.3 s | 13% | 162.6 s | 127.0 s | 22% |
| vaultwarden | 116.4 s | 107.1 s | 8% | 164.7 s | 150.4 s | 9% |
| nushell | 81.0 s | 75.5 s | 7% | 122.1 s | 112.2 s | 8% |
| zola | 117.2 s | 114.7 s | 2% | 126.1 s | 125.9 s | 0% |

- **Deep workspaces gain most.** rust-analyzer, polars and wasmtime chain
  their own crates one after another. rust-analyzer and polars average
  about 3 compilations running at once out of 16 without headstart, and
  6–7 with it.
- **Wide builds that end in one big crate gain least.** Out of 16 job
  slots, zola, vaultwarden and atuin average 5–7 compilations running.
  Their builds end with one crate compiling alone:
  - zola: `minify_html_common`, 81 s of generated tables;
  - vaultwarden: diesel, then the `vaultwarden` binary;
  - atuin: sqlx and its own crates, after SQLite's C build.

  Headstart can start a crate earlier, but it can't split one.
- zed and lemmy, the two slowest, save 1.3 and 2 minutes on check, and
  1.8 and 2.7 minutes on build.

### With the parallel front end (`-Zthreads=8`)

The same projects, with `RUSTFLAGS=-Zthreads=8` on both sides.

| project | check today | check headstart | saved | build today | build headstart | saved |
|---|--:|--:|--:|--:|--:|--:|
| rust-analyzer | 40.1 s | 30.2 s | 25% | 70.1 s | 54.3 s | 22% |
| typst | 63.4 s | 49.6 s | 22% | 133.6 s | 131.3 s | 2% |
| wasmtime | 114.7 s | 99.2 s | 14% | 136.4 s | 118.6 s | 13% |
| lemmy | 194.9 s | 168.8 s | 13% | 244.3 s | 210.3 s | 14% |
| polars | 87.8 s | 76.7 s | 13% | 194.4 s | 176.7 s | 9% |
| zed | 234.3 s | 221.2 s | 6% | 362.8 s | 329.0 s | 9% |
| nushell | 69.4 s | 65.7 s | 5% | 107.6 s | 108.3 s | −1% |
| bevy | 78.3 s | 75.4 s | 4% | 127.3 s | 118.1 s | 7% |
| helix | 26.9 s | 26.0 s | 3% | 53.0 s | 45.9 s | 13% |
| vaultwarden | 65.3 s | 63.3 s | 3% | 101.1 s | 97.2 s | 4% |
| lldap | 51.5 s | 50.5 s | 2% | 78.6 s | 74.9 s | 5% |
| atuin | 109.9 s | 110.5 s | −1% | 136.1 s | 128.7 s | 5% |
| zola | 73.1 s | 74.6 s | −2% | 84.3 s | 80.9 s | 4% |

- **The two overlap.** The parallel front end alone does much of what
  headstart does: rust-analyzer's check goes from 90 s to 40–42 s with
  either one, and to 30 s with both.
- **On top of `-Zthreads`,** headstart adds up to 25%, mostly on deep
  workspaces.
- **Three results are within noise of even:** atuin and zola in check
  (−1%, −2%), and nushell in build (−1%). Their run ranges overlap.
- **wasmtime's check runs were noisy** (79–135 s off, 75–111 s on)
  while the VM's other load came and went.
- **lemmy's diagnostics differ between modes, but not because of
  headstart.**
  - The parallel front end reports some "overflow evaluating the
    requirement" warnings at different lines from run to run, with or
    without headstart.
  - Those warnings are the only difference.
  - With the default front end, all runs are identical.

A first version of this pass found zola 80% *slower* with headstart. See
"Bugs found by the real projects" below.

### Bugs found by the real projects

Until this round, the rustc-perf sweeps built everything in debug mode
with the default front end. The real projects, and a release sweep
added because of them, went down three paths those sweeps never did.
All three are fixed, and each is now covered by a sweep or a test.

1. **Optimized dependencies: "missing optimized MIR".**
   - **Seen in:** typst builds its dependencies at opt-level 2, and zed
     builds its proc macros at 3. Both failed with headstart on.
   - **Cause:** writing early metadata computed deduced parameter
     attributes, which optimizes every function body. The MIR inliner then
     asked dependencies still loaded from early metadata whether they had
     MIR. They said no, and the answer stayed cached after the swap.
   - **Fix:** early metadata no longer records deduced parameter
     attributes, and records optimized MIR only for coroutines.
     `scripts/check-swap.sh` reproduces the bug at opt-level 2 and 3
     without the fix.
2. **Statics evaluated on one thread.**
   - **Seen in:** zola under `-Zthreads=8`, 80% slower with headstart.
     The crate at the end of its build (`minify_html_common`, large
     generated tables) took 78 s to reach its early write, against 26 s
     for all of its analysis with `-Zthreads` alone.
   - **Cause:** the step before the early write evaluated statics in a
     sequential loop, where body checking uses a parallel one.
   - **Fix:** that loop is parallel now, and consts' MIR is prefetched in
     parallel for early metadata, as for full metadata. This also turned
     small losses on bevy, helix and lldap into gains, and moved typst
     from 4% to 22%.
3. **`cargo check --release` asked early crates for MIR.**
   - **Seen in:** the release sweep, where `-Zearly-metadata-verify`
     reported 2,819 cases.
   - **Cause:** in a check build, a crate's full metadata still computed
     the reachable set. At opt-level ≥ 1 that optimizes MIR, asking
     dependencies that check builds never swap to full.
   - **Harm:** the result is never read without code generation, so no
     build failed; the work was wasted and the answers wrong.
   - **Fix:** it's skipped there now.


## Earlier measurements (first, check-only version)

### Correctness

**macOS (M2 Max).** A sweep over all 53 compile benchmarks (not counting
the `-new-solver`, `-nll`, `-tiny` and `-threads4` variants) built each
one with headstart off and on:

- **No ICEs**, and every benchmark's exit status matched between modes.
  Three benchmarks fail in both modes, for reasons unrelated to headstart:
  - libc 0.2.172 uses `#[deprecated]` on foreign modules, which this
    rustc rejects;
  - stm32f4's build script needs a device feature, which rustc-perf
    passes and a plain `cargo check` doesn't;
  - tokio-webpush-simple depends on native-tls 0.1, which doesn't build
    on macOS.

  syn wasn't run: fetching its dependencies needed git authentication.
- **Same diagnostics.** In the timing runs, the sorted `cargo check`
  output was identical between modes for every benchmark.

**Linux (x86_64, AMD EPYC, 16 jobs).** The same sweep passes in both
modes for 52 of 53 benchmarks, including libc, syn and
tokio-webpush-simple, with identical diagnostics. stm32f4 fails in both
modes because it needs a device feature. Its build-script panic
messages differ only in the thread ID.

The sweep found four bugs in the first version of the rustc patch. Each
one was a case where encoding early touched something that only exists
after bodies are checked:

- `required_panic_strategy` scanned every body's MIR.
- A const argument inside a body (`SlimNeon::<1>::new`, in aho-corasick)
  had no type yet.
- A synthetic lifetime definition was looked up in the HIR, which it
  isn't part of (textwrap).
- A static inside a closure created a definition after the table was
  frozen (bstr).

[design.md](design.md) describes the fixes.

rustc's UI suite passes with the patch applied and the flag off:
21967 passed, 0 failed, 421 ignored.

### The interface-body set

Every benchmark, built with headstart on and `-Zearly-metadata-verify`,
checks that no body was type-checked during the early write without
being in the interface set. There are no reports on the 49 benchmarks
that build.

The first run found one bookkeeping bug. For a const argument inside a
closure, the encoder recorded the closure as the enclosing body instead
of the function that contains it. nom's `bits::take` returns
`impl Fn`, so its body is an interface body, and those constants were
wrongly left out.

### Incremental builds

`scripts/check-incremental.sh` applies ten steps to `tests/errors`, with
headstart off and on in separate directories:

- an initial build;
- a body edit;
- adding an `impl Fn` whose closure a dependent calls;
- changing that closure;
- breaking an interface, then fixing it;
- adding a body error, then fixing it;
- an edit in the binary;
- touching every file.

Every step prints the same output in both modes, and the final state
matches a clean build.

It found two bugs:

1. **A crash on the first incremental build.** Metadata encoding asserts
   that it runs outside dependency tracking, and the early write ran
   inside the `analysis` query.
2. **A stale-metadata risk behind it.** In incremental mode, encoding
   reuses the previous `.rmeta` when its inputs are unchanged. Normally it
   depends on `analysis`, which is how it notices new items, and the early
   write had dropped that dependency. It now depends on the crate's item
   list.

### Clippy and rustdoc

Measured on the first, check-only version. Clippy runs as check units,
so it reads early metadata with headstart on. rustdoc units start only
once their dependencies have finished, so they read full metadata; the
comparison checks that the check units underneath produce the same
docs.

- **Clippy.** `cargo check` with `clippy-driver` as the workspace
  wrapper, which is what `cargo clippy` does, over all 49 benchmarks that
  build. The results are identical with headstart off and on: 5534 clippy
  diagnostics in total. Six benchmarks fail in both modes on
  deny-by-default lints, with identical output.
- **rustdoc.** `cargo doc`, including every dependency's docs, on eight
  benchmarks: ripgrep, hyper, regex-automata, image, html5ever, tt-muncher,
  unicode-normalization and eza (up to 30,000 files). Six are
  byte-identical.
  - The other two differ only in rustdoc's merged search index, and, on
    macOS's case-insensitive filesystem, in whether rustix's `_Exit` or
    `_exit` page keeps its file name.
  - Both already depend on scheduling order: changing `-j` with headstart
    *off* reproduces both differences.

### Errors

**Same output.** `scripts/check-errors.sh` builds `tests/errors` in three
scenarios, with headstart off and on, in both human and JSON formats:

- a clean build (with one warning);
- an error in the body of `slow`, the crate `mid` and `app` depend on;
- an error in `app`.

Diagnostics, JSON messages and exit status are identical in every case.
When `slow` fails, `mid` and `app` have already started, but their output
is dropped (see [design.md](design.md#cargo-cargo_headstart1)). The only
difference is their `Checking` progress lines.

**Delay of a crate's own errors.** A crate's body errors now come after
the early metadata write. Across the 280 crates in cargo-0.87.1's build
that write early metadata, that write takes:

| | median | p90 | p99 | max |
|---|--:|--:|--:|--:|
| early write | 4 ms | 34 ms | 249 ms | 532 ms |

That's 5.2 s in total, against 2.3 s for the same crates' metadata today,
which is written at the end. The difference is work the metadata needs
from bodies (constants, opaque types, async functions), done earlier
rather than added. An earlier revision of this version also computed
the reachable set, which walks every inline and generic body. That took the
total to 18.8 s, with a median of 23 ms and a maximum of 1.6 s.

The error at the start of `slow`, in `tests/errors`, is printed at 0.17 s
in both modes.

### Cargo's test suite

With the patch applied and headstart off, cargo's own test suite passes:
4027 passed, 1 failed. The failure,
`aaa_trigger_cross_compile_disabled_check`, only flags that this machine
has no cross-compilation target installed.

### Timing: Linux, AMD EPYC 9554P, 16 jobs, 5 runs

These runs started once the VM was idle (load average 0.57). They use
that version's final patches, which include two fixes that made an
earlier Linux run understate headstart:

- **Binaries waited for their whole dependency tree.** Cargo made a
  check-mode binary wait for the full check of every transitive
  dependency, because a binary normally links. Check builds don't link.
- **Metadata encoding checked bodies early.** The encoder computed the
  reachable set, which forced type-checking of every inline and generic
  body before the early write.

| project | today | headstart | saved | first run |
|---|--:|--:|--:|--:|
| ripgrep-14.1.1 | 10.31 s | 5.45 s | 47% | 30% |
| serde_derive-1.0.219 | 5.76 s | 3.66 s | 36% | 35% |
| piston-image | 6.19 s | 4.02 s | 35% | 23% |
| clap_derive-4.5.32 | 5.86 s | 4.04 s | 31% | 30% |
| unicode-normalization-0.1.24 | 1.93 s | 1.34 s | 31% | 25% |
| tt-muncher | 1.82 s | 1.31 s | 28% | 14% |
| eza-0.21.2 | 26.66 s | 19.68 s | 26% | 18% |
| hyper-1.6.0 | 2.53 s | 1.87 s | 26% | 25% |
| cargo-0.87.1 | 49.78 s | 39.14 s | 21% | 16% |
| image-0.25.6 | 19.33 s | 15.33 s | 21% | 13% |
| regex-automata-0.4.8 | 6.87 s | 5.43 s | 21% | 16% |
| nalgebra-0.33.0 | 22.19 s | 18.71 s | 16% | 16% |
| cargo (old) | 20.23 s | 17.16 s | 15% | 17% |
| wg-grammar | 9.67 s | 8.22 s | 15% | 6% |
| syn-2.0.101 | 3.66 s | 3.14 s | 14% | 14% |
| encoding | 1.11 s | 1.04 s | 6% | 6% |
| cranelift-codegen-0.119.0 | 19.65 s | 18.77 s | 4% | 2% |
| projection-caching | 11.14 s | 10.66 s | 4% | 2% |
| diesel-2.2.10 | 37.71 s | 37.66 s | 0% | 1% |
| html5ever | 16.59 s | 16.79 s | −1% | −1% |
| html5ever-0.31.0 | 7.53 s | 7.70 s | −2% | 0% |

- **html5ever-0.31.0 is slightly slower.** Headstart was slower in 4 of
  5 runs, by about 0.15 s. That fits the early write's cost on a build
  whose critical path can't use it.
- **Everything else is flat or faster.**
- **The sweep still passes.** Rerun on these patches: 52 of 53
  benchmarks pass in both modes with identical diagnostics, and stm32f4
  fails in both.

### Peak memory

These runs sample the total resident memory of all rustc processes every
100 ms during clean `cargo check` builds, on Linux with 16 jobs, median
of 3:

| project | peak today | peak with headstart | change | time today | time with headstart |
|---|--:|--:|--:|--:|--:|
| cargo-0.87.1 | 2.81 GB | 2.69 GB | −4% | 52.5 s | 41.5 s |
| eza-0.21.2 | 2.21 GB | 2.24 GB | +1% | 28.1 s | 21.1 s |
| ripgrep-14.1.1 | 1.63 GB | 1.68 GB | +3% | 10.2 s | 5.6 s |
| image-0.25.6 | 1.92 GB | 2.17 GB | +13% | 19.9 s | 15.7 s |
| nalgebra-0.33.0 | 0.76 GB | 1.05 GB | +39% | 22.9 s | 19.0 s |
| diesel-2.2.10 | 0.75 GB | 0.75 GB | −1% | 38.9 s | 39.5 s |

- **Mostly flat.** With more crates running at once, more of them are
  in memory together.
- **nalgebra is the outlier:** 0.29 GB more, because its large crates now
  overlap.
- **That version's final patches didn't cost speed.** The times,
  measured on those patches, match the timing table above: the interface-body rule and the
  incremental fixes didn't change it.

### With the parallel front end (`-Zthreads=8`)

The parallel front end spreads a crate's type-checking, borrow-checking
and other analysis over up to 8 threads inside one rustc process. Those
threads take tokens from cargo's jobserver, so with `-j16` the whole
build still runs at most 16 things at once, whether they're processes or
threads.

These builds interleave four configurations in one session, on Linux
with 16 jobs: plain; headstart; `RUSTFLAGS=-Zthreads=8`; and both. Each
is a clean `cargo check`, median of 3, with the min–max in brackets:

| project | plain | headstart | `-Zthreads=8` | `-Zthreads=8` + headstart |
|---|--:|--:|--:|--:|
| cargo-0.87.1 | 52.54 s (51.42–53.05) | 42.16 s (42.13–43.06) | 30.23 s (29.89–30.75) | 28.79 s (28.05–29.10) |
| eza-0.21.2 | 27.61 s (26.77–27.88) | 19.81 s (19.67–19.84) | 14.64 s (14.33–14.80) | 14.31 s (14.16–14.37) |
| image-0.25.6 | 19.47 s (19.20–19.76) | 15.82 s (15.69–16.37) | 9.33 s (9.16–9.49) | 9.06 s (8.98–9.90) |
| ripgrep-14.1.1 | 10.31 s (10.23–10.66) | 5.64 s (5.58–5.81) | 4.24 s (4.01–4.31) | 3.32 s (3.25–3.36) |
| regex-automata-0.4.8 | 7.06 s (7.01–7.17) | 5.59 s (5.55–5.70) | 2.55 s (2.48–2.73) | 2.64 s (2.63–2.72) |
| serde_derive-1.0.219 | 5.69 s (5.62–6.14) | 3.65 s (3.61–3.67) | 2.50 s (2.50–2.66) | 2.07 s (2.07–2.09) |
| hyper-1.6.0 | 2.48 s (2.47–2.60) | 1.83 s (1.81–1.85) | 1.07 s (1.03–1.07) | 0.87 s (0.86–0.96) |

- **The parallel front end alone is the bigger win everywhere:** 42–64%
  faster than plain, where headstart alone is 19–45%.
- **On top of it, headstart helps chain-shaped builds most:** ripgrep
  saves 0.92 s (22%), hyper 0.20 s (19%) and serde_derive 0.43 s (17%).
  The large builds gain a little: cargo-0.87.1 1.44 s (5%), image 0.27 s
  (3%), eza 0.33 s (2%). Only cargo-0.87.1's run ranges don't overlap
  the `-Zthreads=8` ones.
- **regex-automata gets 0.09 s (4%) slower** with both, likely the early
  write's cost where the parallel front end has already removed the wait.
- An earlier, separate 3-run session showed cargo-0.87.1 3% slower with
  both. Interleaved, it's 5% faster. At this size, the combination is
  within a few percent either way.

The parallel front end is still nightly-only and off by default. Once it
ships, headstart's value is the last column against the third.

### Incremental edit loop

These runs edit one function body in cargo's own workspace, then run an
incremental `cargo check`, with a warm target directory per mode. Each
number is the median of 5 edits on Linux with 16 jobs:

| edited file | today | headstart | saved |
|---|--:|--:|--:|
| `crates/cargo-util/src/paths.rs` | 6.07 s | 5.72 s | 6% |
| `crates/cargo-util-schemas/src/manifest/mod.rs` | 6.28 s | 5.80 s | 8% |
| `src/compiler/mod.rs` (the `cargo` crate) | 5.65 s | 5.28 s | 7% |

The gain is smaller than in clean builds, because only the edited crate
and its dependents recheck. But it applies to every edit. Even an edit to
the top `cargo` library saves time, because cargo's binaries start on
the library's early metadata.

### Timing: Apple M2 Max, 12 jobs, 5 runs (first version)

| project | today | headstart | saved |
|---|--:|--:|--:|
| clap_derive-4.5.32 | 8.94 s | 3.68 s | 59%* |
| serde_derive-1.0.219 | 3.22 s | 2.30 s | 29% |
| regex-automata-0.4.8 | 3.49 s | 2.54 s | 27% |
| unicode-normalization-0.1.24 | 1.16 s | 0.86 s | 26% |
| tt-muncher | 1.47 s | 1.11 s | 24% |
| hyper-1.6.0 | 1.15 s | 0.98 s | 15% |
| image-0.25.6 | 12.14 s | 10.48 s | 14% |
| cargo (old) | 13.04 s | 11.68 s | 10%* |
| ripgrep-14.1.1 | 4.65 s | 4.21 s | 9% |
| html5ever | 9.52 s | 8.75 s | 8% |
| nalgebra-0.33.0 | 11.23 s | 10.33 s | 8% |
| piston-image | 3.46 s | 3.24 s | 6% |
| projection-caching | 11.48 s | 10.74 s | 6%* |
| wg-grammar | 5.90 s | 5.65 s | 4% |
| diesel-2.2.10 | 22.43 s | 21.77 s | 3% |
| encoding | 0.71 s | 0.69 s | 3% |
| cargo-0.87.1 | 31.78 s | 31.38 s | 1% |
| eza-0.21.2 | 17.20 s | 17.17 s | 0% |
| html5ever-0.31.0 | 4.67 s | 4.69 s | 0% |
| cranelift-codegen-0.119.0 | 10.75 s | 11.16 s | −4% |

\* Noisy: the machine was also syncing files during part of the run. For
example, clap_derive's baseline runs ranged from 4.2 s to 12.2 s. The
rows without a star were consistent across runs. For instance, every
regex-automata, unicode-normalization and serde_derive run was faster
with headstart on.

### Where it doesn't help

- **CPU-bound builds.** cargo-0.87.1 has about 211 s of rustc work. On
  the 12-core Mac, the cores are busy almost until the last crate starts,
  and the first version of headstart saved 1%. On 16 cores the current
  version saves 19% for check and 13% for build. Starting crates earlier helps only when there's an
  idle core to run them on.
- **Build scripts and proc macros.** Build scripts, and C code compiled
  from them, are full builds and gain nothing. The same holds for proc
  macros (syn → serde_derive → ...). In cargo-0.87.1, the libgit2 C build
  sits on the critical path. Headstart makes more crates ready at once,
  and they can crowd that build out.
- **Single-crate benchmarks.** With no dependents, there's nothing to
  start early.
