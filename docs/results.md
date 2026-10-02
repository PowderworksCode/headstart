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

"Reproduction on 4 cores" reruns most of it on a 4-core container, and
"After rebasing onto current master" reruns that on the rebased
patches. "The final series" validates and times the patches as they
are now, after the cleanup, the output locks and the fixes the forced UI
run found, and adds codex-rs. The sections after them are from the
16-core VM.

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

## The final series: 4 cores

The six rustc and three cargo commits in [patches/](../patches), as they
are now, on the same 4-core container, against the same masters
(rust-lang/rust `6006fd0`, cargo `4f3fb24`). Since "After rebasing onto
current master" below, the patches gained the output locks (instead of polling), `-Zheadstart`, the
commit split, and the fixes from the forced UI run.

### Correctness

- **Sweeps** (`scripts/sweep.sh`, `-Zearly-metadata-verify`): `cargo
  check` and `cargo build`, each in debug and release. 106 builds each,
  424 in all: every benchmark builds in both modes with identical
  diagnostics (stm32f4 fails in both, as before), and verify reports
  nothing.
- **`check-errors.sh`:** all 12 scenarios the same in both modes.
- **`check-incremental.sh check` and `build`:** every step matches, and
  the final state matches a clean build.
- **`check-swap.sh`,** now holding the output locks itself: the swap
  gives the same program at every opt-level, and a dependency failing
  after its early write stops the dependent with "a dependency failed to
  compile after writing early metadata".
- **In-tree tests:** `tests/run-make/early-metadata` and
  `tests/ui/rmeta` pass.
- **rustc's UI suite, flag off:** 22172 passed, 0 failed, 262 ignored.
- **rustc's UI suite with `-Zearly-metadata -Zearly-metadata-verify`
  forced on for every test:** 22168 passed, 4 failed. All four differ
  only in output that depends on when bodies are checked:
  - `asm/naked-asm-outside-naked-fn.rs`,
    `consts/qualif-indirect-mutation-fail.rs` and
    `force-inlining/deny-async.rs` report the same errors in another
    order;
  - `treat-err-as-bug/err.rs`, a deliberate ICE, shows the early write in
    its query stack.

  The first forced run found three bug classes, all fixed (see
  [readiness.md](readiness.md#done-since-the-first-review)): an ICE on
  errors in interface bodies (17 tests), async closures' by-move bodies
  created too early and in parallel (2 tests), and waiting for an rlib a
  metadata-only dependency never writes (3 tests).
- **codex-rs** found a regression in that last fix before the timing
  runs: the loader expected an rlib only while its lock existed, so a
  dependency already compiled earlier in the build (`version_check`,
  "required to be available in rlib format") was missed. It now expects
  one if the lock exists or the rlib already does, and
  `tests/run-make/early-metadata` covers it.

### rust-analyzer, 5 runs

| | today | headstart | saved | today range | headstart range | after rebase |
|---|--:|--:|--:|--:|--:|--:|
| `cargo check` | 93.20 s | 70.81 s | 24% | 90.93–95.56 | 70.50–71.13 | 24% |
| `cargo build` | 153.54 s | 130.50 s | 15% | 150.62–154.13 | 128.18–133.18 | 13% |

### codex-rs, 3 runs, with a warm-up build

[openai/codex](https://github.com/openai/codex) `57a38c1` (2026-10-01),
the `codex-rs` workspace: 1,379 compilations, ending in a long chain
through `codex-core`, `codex-app-server` and `codex-tui`.
`scripts/setup-codex.sh` sets it up; three things differ from upstream:

- `allocative` 0.3.6 is patched to drop `impl Allocative for !`, which
  conflicts with `Infallible` now that it's `!` on rustc 1.101-dev
  (E0119). That's codex's problem on any current nightly, not
  headstart's.
- V8 comes from codex's prebuilt release, checksummed as its CI does.
- `codex-voice-host` is excluded: it needs GStreamer ≥ 1.28.

| | today | headstart | saved | today range | headstart range |
|---|--:|--:|--:|--:|--:|
| `cargo check` | 475.92 s | 409.11 s | 14% | 461.51–487.90 | 384.81–415.59 |
| `cargo build` | doesn't fit | | | | |

- **Check:** 14%, with separated ranges and identical diagnostics. The
  schedules average 2.6 compilations running without headstart and 3.1
  with it. The build ends in a serial tail that headstart can shorten but
  not remove: `codex-core` alone takes about 95 s, then
  `codex-app-server` 28 s and `codex-tui` 49 s.
- **Build doesn't fit in this container's 15 GB.** Without headstart, at
  `-j4`, `codex-core`'s rustc was killed by the OOM killer at 13.7 GB
  resident, with `debug = 0` and incremental off. With headstart, more
  compilations are resident at once, so it would need more still. It
  needs a bigger machine (`scripts/bench-suite.sh` includes it), and it's
  the obvious candidate for the memory measurement (readiness item 5).

### rustc-perf, 21 benchmarks, 3 runs

Same sources and order as before. `*`: the off and on ranges overlap.

| benchmark | build today | build headstart | saved | after rebase | check today | check headstart | saved | after rebase |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| serde_derive-1.0.219 | 7.48 s | 4.89 s | 35% | 34% | 4.91 s | 3.18 s | 35% | 34% |
| tt-muncher | 2.00 s | 1.32 s | 34% | 37% | 1.58 s | 1.17 s | 26% | 29% |
| clap_derive-4.5.32 | 7.12 s | 5.04 s | 29% | 33% | 5.01 s | 3.23 s | 36% | 33% |
| unicode-normalization-0.1.24 | 1.72 s | 1.28 s | 26% | 21% | 1.65 s | 1.05 s | 36% | 34% |
| html5ever | 14.76 s | 11.23 s | 24% | 24% | 14.98 s | 10.96 s | 27% | 29% |
| hyper-1.6.0 | 2.31 s | 1.76 s | 24% | 24% | 1.99 s | 1.60 s | 20% | 9% |
| wg-grammar | 8.98 s | 7.03 s | 22% | 21% | 8.61 s | 6.73 s | 22% | 20% |
| nalgebra-0.33.0 | 20.56 s | 17.07 s | 17% | 19% | 19.22 s | 16.43 s | 15% | 16% |
| regex-automata-0.4.8 | 9.31 s | 7.78 s | 16% | 17% | 6.25 s | 4.94 s | 21% | 19% |
| projection-caching | 9.68 s | 8.39 s | 13% | 14% | 8.75 s | 7.65 s | 13% | 3% |
| ripgrep-14.1.1 | 13.90 s | 12.16 s | 13% | 13% | 8.67 s | 6.75 s | 22% | 25% |
| syn-2.0.101 | 5.13 s | 4.49 s | 12% | 10% | 3.00 s | 2.65 s | 12% | −14% |
| image-0.25.6 | 26.13 s | 23.34 s | 11% | 12% | 18.54 s | 15.09 s | 19% | 19% |
| diesel-2.2.10 | 33.32 s | 30.65 s | 8% | 8% | 31.28 s | 28.64 s | 8% | 6% |
| cargo | 74.22 s | 68.36 s | 8% | 4% | 61.47 s | 56.87 s | 7% | 5% |
| eza-0.21.2 | 43.07 s | 40.16 s | 7% | 9% | 37.59 s | 34.75 s | 8% | 5% |
| html5ever-0.31.0 | 8.47 s | 7.97 s | 6% | 6% | 7.69 s | 7.22 s | 6%* | 8% |
| piston-image | 8.75 s | 8.38 s | 4%* | 10% | 6.52 s | 5.50 s | 16% | 16% |
| cargo-0.87.1 | 143.25 s | 139.10 s | 3% | 6% | 84.68 s | 81.29 s | 4% | 4% |
| encoding | 1.64 s | 1.60 s | 2%* | 2% | 1.10 s | 1.07 s | 3%* | 4% |
| cranelift-codegen-0.119.0 | 28.73 s | 28.22 s | 2% | 15% | 17.55 s | 17.06 s | 3% | −6% |

- **All 21 are faster in both check (3–36%) and build (2–35%).** In
  check, only html5ever-0.31.0 and encoding have overlapping ranges; in
  build, only piston-image and encoding.
- **The outliers after the rebase are gone.** syn's check (−14% then)
  is 12%, hyper's 20% and projection-caching's 13%, as the 5-run re-time
  predicted. cranelift-codegen's build (15%, overlapping, then; 5%
  before the rebase) is 2%.
- **Diagnostics were identical** in every run.
- **The host was faster this time:** cargo-0.87.1's build took 143 s
  without headstart, against 173 s after the rebase. As before, compare
  the savings, not the times.

## After rebasing onto current master: 4 cores

Both patches rebased onto rust-lang/rust `6006fd0` and cargo `4f3fb24`
(the masters of 2026-10-01, five days after the previous pins), then the
whole 4-core set rerun on the same container. The patches applied without
conflicts; only hunk offsets moved.

### Correctness

- **Sweeps** (`scripts/sweep.sh`, `-Zearly-metadata-verify`): `cargo
  check` and `cargo build`, debug. 106 builds each; every benchmark
  builds in both modes with identical diagnostics, and verify reports
  nothing. stm32f4 fails in both modes as before. With headstart it
  takes 6.4 s to fail instead of 1.2 s: more crates are already running
  when its build script fails, and cargo waits for them. That's the
  wasted work on failure that [design.md](design.md#risks) describes.
- **`check-swap.sh`** passes at every opt-level.
- **`check-errors.sh`:** all 12 scenarios are the same in both modes.
- **`check-incremental.sh check` and `build`:** all 11 steps match.
- **Freshness:** a binary is relinked after its dependency's rlib
  changes, with headstart off and on.
- **Test suites, with the patches applied and headstart off:**
  - rustc's UI suite: 22170 passed, 0 failed, 262 ignored.
  - cargo's testsuite, filtered to freshness, fingerprint, build_script,
    pipelining, rebuild and docscrape tests, with
    `CFG_DISABLE_CROSS_TESTS=1`: 337 passed, 0 failed.

### rust-analyzer, 5 runs

| | today | headstart | saved | today range | headstart range | before rebase |
|---|--:|--:|--:|--:|--:|--:|
| `cargo check` | 96.10 s | 72.93 s | 24% | 95.69–96.79 | 72.39–73.51 | 24% |
| `cargo build` | 161.75 s | 140.33 s | 13% | 159.25–168.52 | 138.13–142.87 | 15% |

The absolute times are 10–30% higher than before the rebase, because the
container's host was slower that day: rust-analyzer's check went from
86 s to 96 s, and lldap's build from 155 s to 204 s, off and on alike.
The savings are what compare.

### rustc-perf, 21 benchmarks, 3 runs

Same sources as before (copied out of the rustc-perf submodule at
`94df17b`). `*`: the off and on ranges overlap.

| benchmark | build today | build headstart | saved | before rebase | check today | check headstart | saved | before rebase |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| tt-muncher | 2.43 s | 1.53 s | 37% | 33% | 1.68 s | 1.20 s | 29% | 28% |
| serde_derive-1.0.219 | 8.90 s | 5.88 s | 34% | 32% | 5.31 s | 3.49 s | 34% | 34% |
| clap_derive-4.5.32 | 8.63 s | 5.77 s | 33% | 28% | 5.30 s | 3.54 s | 33% | 32% |
| hyper-1.6.0 | 2.79 s | 2.11 s | 24% | 21% | 2.26 s | 2.05 s | 9% | 22% |
| html5ever | 16.53 s | 12.58 s | 24% | 26% | 16.29 s | 11.59 s | 29% | 26% |
| unicode-normalization-0.1.24 | 2.14 s | 1.69 s | 21%* | 31% | 1.76 s | 1.16 s | 34% | 35% |
| wg-grammar | 9.86 s | 7.79 s | 21% | 21% | 9.63 s | 7.68 s | 20% | 22% |
| nalgebra-0.33.0 | 23.35 s | 18.98 s | 19% | 18% | 21.28 s | 17.98 s | 16% | 18% |
| regex-automata-0.4.8 | 10.66 s | 8.89 s | 17% | 16% | 6.79 s | 5.49 s | 19% | 19% |
| cranelift-codegen-0.119.0 | 40.66 s | 34.49 s | 15%* | 5% | 21.14 s | 22.39 s | −6%* | 5% |
| projection-caching | 10.76 s | 9.28 s | 14% | 9% | 11.35 s | 11.03 s | 3%* | 14% |
| ripgrep-14.1.1 | 16.90 s | 14.66 s | 13% | 12% | 9.47 s | 7.08 s | 25% | 21% |
| image-0.25.6 | 30.39 s | 26.69 s | 12% | 14% | 20.43 s | 16.51 s | 19% | 13% |
| syn-2.0.101 | 5.63 s | 5.06 s | 10% | 12% | 4.71 s | 5.38 s | −14%* | 10% |
| piston-image | 10.42 s | 9.39 s | 10% | 10% | 6.91 s | 5.77 s | 16% | 13% |
| eza-0.21.2 | 50.36 s | 45.69 s | 9% | 10% | 40.43 s | 38.34 s | 5% | 5% |
| diesel-2.2.10 | 38.79 s | 35.60 s | 8% | 9% | 38.28 s | 36.12 s | 6%* | 8% |
| cargo-0.87.1 | 172.73 s | 161.63 s | 6%* | 3% | 97.54 s | 93.23 s | 4% | 5% |
| html5ever-0.31.0 | 9.24 s | 8.66 s | 6% | 9% | 9.14 s | 8.45 s | 8%* | 7% |
| cargo | 87.37 s | 83.91 s | 4% | 8% | 71.89 s | 68.14 s | 5%* | 8% |
| encoding | 1.90 s | 1.87 s | 2%* | 1% | 1.30 s | 1.25 s | 4%* | 15% |

- **Build:** all 21 are faster (2–37%), within a few points of before
  the rebase.
- **Check:** in 3 runs, 19 of 21 are faster.
  - syn (−14%) and cranelift-codegen (−6%) aren't.
  - hyper, projection-caching and encoding gained less than before.
  - Their runs scattered widely: syn's took 3.9–6.2 s, where before they
    spanned 0.15 s, and its fastest run was with headstart.

  A 5-run re-time of the five weakest check results puts them back in
  line with before:

  | benchmark | 3 runs | 5 runs | 5-run ranges, off / on | before rebase |
  |---|--:|--:|--:|--:|
  | hyper-1.6.0 | 9% | 20% | 2.26–2.47 / 1.73–1.93 s | 22% |
  | syn-2.0.101 | −14% | 15% | 3.66–3.94 / 3.03–3.28 s | 10% |
  | projection-caching | 3% | 14% | 10.53–11.67 / 9.16–9.62 s | 14% |
  | encoding | 4% | 4% | 1.24–1.38 / 1.21–1.32 s | 15% |
  | cranelift-codegen-0.119.0 | −6% | 2% | 20.91–22.40 / 19.86–22.09 s | 5% |

### Real projects, 3 runs, with a warm-up build

| project | check today | check headstart | saved | before rebase | build today | build headstart | saved | before rebase |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| helix | 88.4 s | 69.5 s | 21% | 17% | 142.3 s | 128.1 s | 10% | 11% |
| wasmtime | 192.8 s | 163.9 s | 15% | 16% | 323.1 s | 309.5 s | 4% | 5% |
| typst | 177.1 s | 169.8 s | 4%* | 4% | 486.0 s | 506.2 s | −4%* | 1% |
| lldap | 120.5 s | 120.6 s | 0%* | 0% | 204.1 s | 199.4 s | 2%* | 0% |
| bevy | 162.9 s | 164.5 s | −1%* | −1% | 359.3 s | 365.9 s | −2%* | 0% |

`*`: the off and on ranges overlap.

- **The same as before the rebase,** within the run-to-run noise:
  - helix and wasmtime gain in check and build, with separated ranges;
  - typst, lldap and bevy are within noise of even.
- **typst's build (−4%)** is one slow run. In run 2, the headstart build's
  compilations used 14% more CPU time (2,264 s, paused time excluded)
  than the same compilations in run 1 (1,985 s). The other two pairs are
  even: 482 vs 482 s, and 508 vs 506 s.
- **The cost on a saturated machine.** With headstart, the same builds
  spend more rustc CPU time:
  - typst's build: 5–7% more, from the early write and from more
    compilations competing for cache and memory bandwidth;
  - bevy's build: about 3% more.

  With no idle core to win back, that's what keeps typst, lldap and bevy
  at even, or slightly behind (bevy's build: −2%, overlapping ranges).

## Reproduction on 4 cores: Claude Code container, 4 jobs

A rerun of the benchmarks on a much smaller machine than the 16-core VM
below, to check that the results reproduce and to see what a
laptop-sized machine gets (open work item "Fewer cores").

- **Machine:** a Claude Code cloud container, Intel Xeon @ 2.1 GHz, 4
  cores, 15 GB RAM, ~30 GB of disk. `-j 4` throughout.
- **Build:** the same patches and `config/bootstrap.toml`, except
  `incremental = false` for the compiler's own build, to save disk. Both
  modes use the same compiler, so this doesn't affect the comparison.
- **Load:** the container is shared-tenancy, and it restarted twice
  during the session. After the second restart the same builds ran about
  20% slower (lldap took 110 s where it had taken 90 s), while the saved
  percentages stayed put (helix 18% before, 17% after). Every table
  compares off and on runs from the same session, alternating, never
  across a restart.
- **Discarded runs:** the first real-project pass, cut short by a
  restart; it had no warm-up, and a stray process skewed one lldap run.
  The tables come from a full rerun.
- **Result:**
  - Every build succeeded once bevy's system libraries were installed,
    with identical diagnostics in both modes.
  - Nothing is meaningfully slower. The worst result is bevy's check at
    −1%, within noise.

### Correctness

- **`scripts/check-swap.sh`** passes at every opt-level.
- **`scripts/check-errors.sh`** reports all 12 scenarios the same in both
  modes.
- **With the two cargo fixes** from [readiness.md](readiness.md#fixed-in-this-round):
  - `check-errors.sh` passes again, and so do
    `check-incremental.sh check` and `check-incremental.sh build`.
  - The cargo testsuite tests for freshness, fingerprints, build scripts,
    pipelining, rebuilds and docscrape pass: 336 passed. The one failure
    needs an i686 cross target the container doesn't have.

### rust-analyzer, 5 runs

| | today | headstart | saved | today range | headstart range | 16-core VM |
|---|--:|--:|--:|--:|--:|--:|
| `cargo check` | 86.18 s | 65.36 s | 24% | 84.32–86.83 | 64.66–66.35 | 54% |
| `cargo build` | 146.70 s | 125.34 s | 15% | 145.76–147.50 | 122.87–125.58 | 42% |

The ranges don't overlap. The smaller saving is the core count, not
headstart:

- **Check.** Without headstart, 2.7 compilations run on average, out of
  4 slots; with it, 3.8. The build is about 230 s of rustc work, so no
  schedule on 4 cores can finish in under ~57 s. Headstart gets 65 s,
  about 70% of the most that can be saved here.
- **Build.** 2.8 running without headstart, 3.6 with it (paused
  compilations excluded; they spent 95 s paused, holding no slot). About
  415 s of rustc work, so the floor is ~104 s; headstart gets 125 s.
- **On 16 cores,** the same work has a floor of ~14 s for check, and
  the build without headstart is bound by the crate chain instead, which
  is what headstart shortens. That's the room the 54% came from.

### rustc-perf, 21 benchmarks, 3 runs

Sorted by the `cargo build` saving. The VM columns are from "Timing,
current version" below.

| benchmark | build today | build headstart | saved | 16-core VM | check today | check headstart | saved | 16-core VM |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| tt-muncher | 2.01 s | 1.35 s | 33% | 32% | 1.47 s | 1.06 s | 28% | 28% |
| serde_derive-1.0.219 | 7.50 s | 5.12 s | 32% | 37% | 4.88 s | 3.22 s | 34% | 36% |
| unicode-normalization-0.1.24 | 1.77 s | 1.22 s | 31% | 24% | 1.57 s | 1.02 s | 35% | 31% |
| clap_derive-4.5.32 | 7.22 s | 5.20 s | 28% | 27% | 4.72 s | 3.22 s | 32% | 30% |
| html5ever | 14.49 s | 10.72 s | 26% | 27% | 14.10 s | 10.47 s | 26% | 27% |
| hyper-1.6.0 | 2.38 s | 1.87 s | 21% | 24% | 2.01 s | 1.57 s | 22% | 24% |
| wg-grammar | 8.99 s | 7.14 s | 21% | 22% | 8.67 s | 6.80 s | 22% | 19% |
| nalgebra-0.33.0 | 20.88 s | 17.16 s | 18% | 23% | 19.23 s | 15.73 s | 18% | 22% |
| regex-automata-0.4.8 | 9.58 s | 8.06 s | 16% | 22% | 6.40 s | 5.16 s | 19% | 22% |
| image-0.25.6 | 26.59 s | 22.98 s | 14% | 22% | 17.88 s | 15.47 s | 13% | 28% |
| ripgrep-14.1.1 | 14.35 s | 12.58 s | 12% | 34% | 8.48 s | 6.72 s | 21% | 46% |
| syn-2.0.101 | 4.88 s | 4.31 s | 12% | 14% | 3.14 s | 2.83 s | 10% | 13% |
| piston-image | 9.43 s | 8.47 s | 10% | 31% | 5.93 s | 5.14 s | 13% | 35% |
| eza-0.21.2 | 45.47 s | 41.08 s | 10% | 35% | 36.29 s | 34.31 s | 5% | 30% |
| html5ever-0.31.0 | 8.18 s | 7.41 s | 9% | 18% | 7.42 s | 6.92 s | 7% | 15% |
| diesel-2.2.10 | 32.86 s | 29.80 s | 9% | 9% | 31.97 s | 29.41 s | 8% | 9% |
| projection-caching | 9.23 s | 8.43 s | 9% | 13% | 9.25 s | 7.93 s | 14% | 15% |
| cargo | 73.12 s | 67.33 s | 8% | 16% | 61.54 s | 56.81 s | 8% | 18% |
| cranelift-codegen-0.119.0 | 27.22 s | 25.76 s | 5% | 8% | 18.08 s | 17.24 s | 5% | 9% |
| cargo-0.87.1 | 152.19 s | 147.16 s | 3% | 13% | 85.82 s | 81.95 s | 5% | 19% |
| encoding | 1.45 s | 1.43 s | 1% | 6% | 1.23 s | 1.05 s | 15% | 5% |

- **Chain-shaped builds reproduce almost exactly:** tt-muncher,
  serde_derive, clap_derive, html5ever, hyper, wg-grammar and diesel are
  within a few points of the 16-core numbers. They never had more than a
  few crates ready at once, so 4 cores is enough to run them.
- **Wide builds lose most of their gain:** ripgrep (46% → 21% for
  check), eza (30% → 5%), piston-image and cargo-0.87.1. Headstart makes
  more crates ready at once, and on 4 cores there's nowhere to run them.
- **Ranges.** For check, every headstart run was faster than every
  run without it on 20 of the 21; encoding's ranges overlap on a 1-second
  build.

### Real projects, 3 runs

Each project gets one untimed warm-up build first (`bench.sh -w`), then
alternating runs. helix's build script compiles its tree-sitter grammars
into the source tree on the first build, which took 185 s instead of
57 s; without the warm-up, that lands on the first run, which is always
headstart off. The VM runs had no warm-up, so helix's VM numbers include
that cost in its first off run (the median of 3 limits the effect).

| project | check today | check headstart | saved | 16-core VM | build today | build headstart | saved | 16-core VM |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| rust-analyzer | 86.2 s | 65.4 s | 24% | 54% | 146.7 s | 125.3 s | 15% | 42% |
| helix | 74.1 s | 61.4 s | 17% | 31% | 124.4 s | 111.2 s | 11% | 17% |
| wasmtime | 173.4 s | 145.9 s | 16% | 47% | 280.2 s | 265.5 s | 5% | 36% |
| typst | 160.2 s | 154.2 s | 4% | 26% | 422.1 s | 419.5 s | 1% | 13% |
| lldap | 109.6 s | 109.5 s | 0% | 18% | 154.6 s | 154.6 s | 0% | 23% |
| bevy | 146.7 s | 148.6 s | −1% | 29% | 307.0 s | 308.0 s | 0% | 30% |

rust-analyzer is the 5-run measurement above.

- **Where cores were idle, it still pays.** On rust-analyzer, helix and
  wasmtime, in both check and build, every run with headstart beat every
  run without it.
- **Where 4 cores are already full, there's nothing to fill.** Without
  headstart, bevy's build already keeps 3.76 of 4 compilations running;
  lldap's check 3.0 (plus C build scripts); typst builds its dependencies
  at opt-level 2, so code generation dominates. These are even:
  - Overlapping ranges: bevy's check (−1%; 144.9–149.1 s off, 146.4–149.3 s
    on) and build (0.3% slower), lldap's check and build, and typst's build;
  - bevy's build with headstart spent about 3% more rustc time (the early
    write, and more compilations competing for the same cores), which is
    the cost that shows when there's no idle core to win back.

  That's the saturated case of open work item 1, measured.
- **Not measured here:** polars, zed and lemmy need tens of GB for a
  debug build, more than the container's disk. nushell, vaultwarden,
  atuin and zola weren't attempted, for time.
- **A bevy run that failed in both modes** (missing system libraries,
  before they were installed) reported the same error in both, differing
  only in the panicking thread's ID.

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
