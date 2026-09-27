# Results

All numbers are clean `cargo check` builds of rustc-perf benchmarks
(`rustc/src/tools/rustc-perf/collector/compile-benchmarks`), taken with
`scripts/bench.sh`. Each run alternates headstart off and on, using the
same patched rustc and cargo. With headstart off, both behave like
upstream. The tables give medians.

## Correctness

**macOS (M2 Max).** A sweep over all 53 multi-file benchmarks (the
rustc-perf directories with a `Cargo.toml`, minus solver and `-nll`
variants) built each one with headstart off and on:

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

## The interface-body set

Every benchmark, built with headstart on and `-Zearly-metadata-verify`,
checks that no body was type-checked during the early write without
being in the interface set. There are no reports on the 49 benchmarks
that build.

The first run found one bookkeeping bug. For a const argument inside a
closure, the encoder recorded the closure as the enclosing body instead
of the function that contains it. nom's `bits::take` returns
`impl Fn`, so its body is an interface body, and those constants were
wrongly left out.

## Incremental builds

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

## Clippy and rustdoc

Both read check-mode metadata, so both read early metadata with headstart
on.

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

## Errors

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
rather than added. The first version of the patch also computed the
reachable set, which walks every inline and generic body. That took the
total to 18.8 s, with a median of 23 ms and a maximum of 1.6 s.

The error at the start of `slow`, in `tests/errors`, is printed at 0.17 s
in both modes.

## Cargo's test suite

With the patch applied and headstart off, cargo's own test suite passes:
4027 passed, 1 failed. The failure,
`aaa_trigger_cross_compile_disabled_check`, only flags that this machine
has no cross-compilation target installed.

## Timing: Linux, AMD EPYC 9554P, 16 jobs, 5 runs

These runs started once the VM was idle (load average 0.57). They use
the current patches, which include two fixes that made an earlier Linux
run understate headstart:

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

## Peak memory

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
- **The final patches don't cost speed.** The times, measured on those
  patches, match the timing table above: the interface-body rule and the
  incremental fixes didn't change it.

## With the parallel front end (`-Zthreads=8`)

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
  faster than plain, where headstart alone is 20–45%.
- **On top of it, headstart helps chain-shaped builds most:** ripgrep
  saves 0.92 s (22%), hyper 0.20 s (19%) and serde_derive 0.43 s (17%).
  The large builds gain a little: cargo-0.87.1 1.44 s (5%), image 0.27 s
  (3%), eza 0.33 s (2%). These ranges don't overlap the `-Zthreads=8`
  ones.
- **regex-automata gets 0.09 s (4%) slower** with both, likely the early
  write's cost where the parallel front end has already removed the wait.
- An earlier, separate 3-run session showed cargo-0.87.1 3% slower with
  both. Interleaved, it's 5% faster. At this size, the combination is
  within a few percent either way.

The parallel front end is still nightly-only and off by default. Once it
ships, headstart's value is the last column against the third.

## Incremental edit loop

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

## Timing: Apple M2 Max, 12 jobs, 5 runs (first version)

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

## Where it doesn't help

- **CPU-bound builds.** cargo-0.87.1 has about 211 s of rustc work. On
  the 12-core Mac, the cores are busy almost until the last crate starts,
  and the first version of headstart saved 1%. On 16 cores the current
  version saves 21%. Starting crates earlier helps only when there's an
  idle core to run them on.
- **Build scripts and proc macros.** Build scripts, and C code compiled
  from them, are full builds and gain nothing. The same holds for proc
  macros (syn → serde_derive → ...). In cargo-0.87.1, the libgit2 C build
  sits on the critical path. Headstart makes more crates ready at once,
  and they can crowd that build out.
- **Single-crate benchmarks.** With no dependents, there's nothing to
  start early.
