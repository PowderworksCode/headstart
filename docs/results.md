# Results

All numbers are clean `cargo check` builds of rustc-perf benchmarks
(`rustc/src/tools/rustc-perf/collector/compile-benchmarks`), taken with
`scripts/bench.sh`. Each run alternates headstart off and on, using the
same patched rustc and cargo. With headstart off, both behave like
upstream. The tables give medians. The raw runs, the per-rustc schedules
and the diagnostics are in [`results/`](../results).

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

These runs started once the VM was idle (load average 0.57)
([raw runs](../results/timing-2026-09-27-linux-v2/runs.tsv)). They use
the current patches, which include two fixes that made an earlier Linux
run ([raw runs](../results/timing-2026-09-27-linux/runs.tsv)) understate
headstart:

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
