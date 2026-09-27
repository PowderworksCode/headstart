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

## Timing: Apple M2 Max, 12 jobs, 5 runs

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

- **CPU-bound builds.** cargo-0.87.1 has about 211 s of rustc work on 12
  cores, and the cores are busy almost until the last crate starts.
  Starting crates earlier can't help when there's no idle core to run
  them on.
- **Build scripts and proc macros.** Build scripts, and C code compiled
  from them, are full builds and gain nothing. The same holds for proc
  macros (syn → serde_derive → ...). In cargo-0.87.1, the libgit2 C build
  sits on the critical path. Headstart makes more crates ready at once,
  and they can crowd that build out.
- **Single-crate benchmarks.** With no dependents, there's nothing to
  start early.
