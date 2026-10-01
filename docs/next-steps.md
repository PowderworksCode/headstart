# Next steps

Where headstart stands, what's left, and how to do each piece. Written
at the end of the round that added the real-project measurements
(PR #1, at commit f156b9f).

## Where it stands

- **Works, for both `cargo check` and `cargo build`.** Dependents start
  on a crate's early metadata and swap in its full metadata before code
  generation.
- **Faster everywhere on rustc's default front end.**
  - 13 real projects: 2–54% for check and 0–42% for build.
  - 21 rustc-perf benchmarks: 5–46% for check and 6–37% for build.
  See [results.md](results.md).
- **With the parallel front end (`-Zthreads=8`),** most of the gain
  overlaps. On top of it, headstart adds up to 25% on real projects, and
  up to 32% on rustc-perf. Three real-project results are within noise
  of even (−1% to −2%).
- **Reproduced on a 4-core container** (see results.md): smaller gains,
  as expected with fewer idle cores.
  - rust-analyzer: 24% for check, 15% for build.
  - Nothing meaningfully slower.
  - [readiness.md](readiness.md) assesses whether it's ready to bring to
    the compiler and cargo teams.
- **Correctness evidence:**
  - Sweeps of all 53 rustc-perf benchmarks with `-Zearly-metadata-verify`:
    debug, release and `-Zthreads=8`, in check and build.
  - `check-errors.sh`, `check-incremental.sh` and `check-swap.sh`.
  - rustc's UI suite and cargo's test suite, with headstart off (the
    patches don't change anything else).
- **Three bugs found this round, all fixed.** Real projects hit paths the
  debug-only benchmark sweeps never did:
  - optimized dependencies (typst, zed);
  - large static tables under `-Zthreads` (zola);
  - `cargo check --release`.

  A review of the PR also found that rustc didn't withdraw early metadata
  when code generation failed during linking. Only cargo covered that.
  The guard now lasts through linking.

## Moving to Claude Code containers

Nothing in the repo depends on the VM any more. The one-off driver
scripts that lived in its `/tmp` are now `scripts/sweep.sh` and
`scripts/real-projects.sh`.

### What an environment needs

- **Machine:** Linux x86_64.
  - Cores: timings so far use 16 jobs on 16 cores; set `-j` to the core
    count.
  - Memory: 64 GB was never a limit; peak use for the large projects
    hasn't been measured.
- **Disk:** at least 100 GB free.
  - The rustc build is 12 GB, and cargo's `target` 13 GB.
  - The crates.io registry cache is 8 GB.
  - A single debug build of zed or lemmy takes tens of GB while it runs.
    `bench.sh` deletes each project's `target` when done with it.
- **Network:** GitHub, crates.io, and rustc's CI LLVM download
  (`download-ci-llvm = true` in `config/bootstrap.toml`).
- **Toolchains:** rustup with Rust 1.98.0, which builds the pinned cargo.
- **`rsync`**, which `bench.sh` uses to copy each project. The Claude Code
  container didn't have it.
- **System packages** for the real projects: `cmake clang pkg-config
  protobuf-compiler nasm perl`, plus the dev packages for OpenSSL, SQLite,
  libpq, ALSA, libudev, X11, xkbcommon, Wayland, fontconfig, freetype and
  zstd (on Debian/Ubuntu: `libssl-dev libsqlite3-dev libpq-dev
  libasound2-dev libudev-dev libx11-dev libxkbcommon-dev libwayland-dev
  libfontconfig-dev libfreetype-dev libzstd-dev`).

### Setup

```sh
scripts/setup.sh                                   # submodules, patches, build rustc and cargo
git -C rustc submodule update --init --depth 1 src/tools/rustc-perf
scripts/real-projects.sh ~/hs-real > /dev/null     # clone the 13 projects at the measured commits
```

`setup.sh` builds rustc from scratch; with CI LLVM, that's the compiler
and standard library only. A rebuild after editing the patch takes about
1.5 minutes on 16 cores.

### Running things

| what | command | time on 16 cores |
|---|---|--:|
| correctness sweep | `scripts/sweep.sh -c check` (also `-c build`, `-r`, `-t`) | 7–18 min each |
| swap test | `scripts/check-swap.sh` | 1 min |
| errors and incremental | `scripts/check-errors.sh`, `scripts/check-incremental.sh check\|build` | minutes |
| rustc-perf timing | `scripts/bench.sh -n 5 -c build <benchmarks>` | 25–60 min per mode |
| real-project timing | `scripts/bench.sh -n 3 -c check $(scripts/real-projects.sh ~/hs-real)` | 1–4 h per pass |
| rustc UI suite | `(cd rustc && ./x test --stage 1 tests/ui)` | ~3 min |
| cargo test suite | `(cd cargo && cargo +1.98.0 test --no-fail-fast)` (see SIGINT below) | ~3 min |

**Lessons from the Claude Code container** (4 cores, 15 GB RAM, ~30 GB
of disk):

- **The container is reclaimed when the session goes idle,** which kills
  detached benchmark runs. Keep the session active while one runs, and
  use a driver that skips finished work.
  - Results under `results/` survived both restarts.
  - Write one `bench.sh` out-dir per project, so a restart costs one
    project's runs, not the whole pass.
- **Absolute times move between restarts** (about 20% after the second
  one), so compare off and on within a session only. `bench.sh` already
  does.
- **Disk:**
  - The compiler build with `incremental = false` is 4.2 GB.
  - The registry for rust-analyzer, six real projects and the rustc-perf
    set is 4 GB.
  - bevy's debug build peaked at about 11 GB.
  - helix's work copy holds 2.5 GB of compiled grammars.
  - polars, zed and lemmy don't fit.
- **One-time build-script work** outside `target` (helix's grammars) lands
  on the first timed run. Use `bench.sh -w` for real projects.

**Lessons from the VM:**

- **Timing needs a quiet machine.**
  - `bench.sh` alternates off and on runs, so steady background load
    affects both sides alike.
  - But load that comes and goes adds noise. wasmtime's `-Zthreads`
    runs ranged from 79 to 135 s while another session's jobs ran.
  - Record `/proc/loadavg` with every run, as the drivers here did.
  - If containers share hosts, prefer more runs and report ranges.
- **Correctness runs don't need a quiet machine,** and can run alongside
  other work.
- **Detach long runs.** Use `setsid ... < /dev/null &` and write a marker
  line when done. A run tied to an ssh session dies with it.
- **Background jobs ignore SIGINT.** bash starts `... &` jobs with SIGINT
  and SIGQUIT ignored, and every child inherits that. cargo's
  `death::ctrl_c_kills_everyone` test then hangs forever. Restore the
  defaults before exec'ing the test run, e.g.:

  ```sh
  python3 -c 'import os, signal; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp("cargo", ["cargo", "+1.98.0", "test", "--no-fail-fast"])'
  ```
- **Keep `RUSTC_WRAPPER` explicit.** The VM's global cargo config used
  sccache; `bench.sh` overrides it with `scripts/log-rustc`, and anything
  run by hand should set it too.
- **`results/` is gitignored.**
  - Summaries go into `docs/results.md`.
  - Raw schedules (`results/*/schedules/*.txt`) are what
    `scripts/critical-path.py` reads.
  - They're small, so they're worth keeping as artifacts.

## Open work, in priority order

### 1. Scheduling when the machine is saturated

**Problem.** Headstart keeps more compilations alive, and a paused one
resumes without waiting for a free job slot. When the machine is busy,
that crowds the critical path:
- atuin under `-Zthreads=8` is 1% slower;
- its critical path starts with `libsqlite3-sys`'s C build, which
  starts later with headstart;
- its own crates each run slower.

**How:**
- Add a cargo knob for A/B runs, e.g. `CARGO_HEADSTART_RESUME=slot`, so a
  resumed job waits for a slot. That's the `slot_holders()` accounting in
  `src/compiler/job_queue/mod.rs`.
  - Resuming without a slot fixed cargo-0.87.1 on the default front end
    (−8% → +13%).
  - It may be the wrong choice when each job runs 8 threads.
- Try prioritizing build scripts, and units with many dependents, over
  units that headstart just unblocked.
- Measure each change with `bench.sh` on atuin, cargo-0.87.1, eza and
  regex-automata.
- Use `critical-path.py` to see where the critical path's time goes,
  including held units and time paused vs. waiting for a slot.

### 2. Fewer cores

**Problem.** Laptops have 8–12 cores. The machine saturates sooner there,
so there's less idle time for headstart to fill.

**Done at 4 jobs** (results.md, "Reproduction on 4 cores"):
- rust-analyzer saves 24% for check and 15% for build.
- The rustc-perf set saves 1–35%.
- Wide real projects come out even (lldap, typst, bevy: −1% to +4%).
- The schedules show 4 cores nearly saturated with headstart on.

**Still to do:** `bench.sh -j 8` on the same set, the common laptop size,
and `-Zthreads` at 4 and 8 jobs.

### 3. Memory

**Problem.** Paused compilers stay in memory, and cargo doesn't limit
how many there are. Peak memory has only been measured for the first,
check-only version: −4% to +39%.

**How:**
- Run `scripts/bench-mem.sh` on `cargo build` for the real projects (zed,
  lemmy and polars are the likely maxima).
- If peaks matter, cap the number of paused jobs in cargo (e.g. at
  `-j`), and don't start new units past the cap.

### 4. Release builds and incremental timing

**Problem.** Release builds are covered for correctness (sweeps), but
not timed. The incremental edit-loop numbers (6–8%) are from the
check-only version.

**How:**
- Real-project `cargo build --release` timing: `bench.sh` specs with
  `::--release`.
- `scripts/bench-incremental.sh` under `cargo build`.

### 5. Tests that can live upstream

**Problem.** The evidence lives in shell scripts here.

**How:**
- **rustc:**
  - Turn `check-swap.sh` into a `run-make` test: build a crate, hide its
    full metadata, start the dependent, restore the files on the
    `wait-metadata` notification.
  - Add UI tests for `-Zearly-metadata-verify`.
  - Run the UI suite with the flag forced on, via compiletest's
    `--target-rustcflags=-Zearly-metadata`, to see what breaks.
- **cargo:** testsuite tests for:
  - provisional output (a dependent's warnings dropped when its
    dependency fails);
  - retraction (the early file deleted on failure);
  - pause accounting (a paused job frees its slot).

### 6. Platforms

**Problem.**
- **Windows:** retraction deletes a file that dependents may have
  memory-mapped, which can fail there. This is untested.
- **macOS:** only the first version was measured.

**How:** a Windows CI run of `check-errors.sh` (the retraction
scenarios), and a macOS timing pass.

### 7. Clippy and rustdoc on the current version

**Problem.** Both were verified identical only for the check-only
version.

**How:** rerun the clippy and rustdoc comparisons from `results.md`
("Clippy and rustdoc") on the current patches.

### 8. Rebase onto a newer rustc

**Problem.** The patch is against rustc `a22b02e` and cargo `3d7cf6e`.
meilisearch's current code no longer compiles with that rustc, with or
without headstart.

**How:**
- Bump the submodules and reapply the patches.
- Expect conflicts in `rustc_metadata` (`encoder.rs`, `creader.rs`,
  `locator.rs`), and in `rustc_interface/src/passes.rs`.
- Rebuild, then run `check-swap.sh` and the sweeps before any timing.

### 9. The path upstream

**Problem.** This is a proposal-sized change to both tools.

**How:** pieces that could land separately, roughly in order:

1. **rustc: skip the reachable set in full metadata without codegen.**
   It's never read there, and computing it optimizes MIR at
   opt-level ≥ 1. Useful without headstart; small.
2. **rustc: split `analysis` with `analysis_interfaces`.** A refactor with
   no behavior change.
3. **rustc: `-Zearly-metadata`:**
   - the early file, the loader, the swap to full metadata, and the
     `wait-metadata`/`resume` notifications;
   - it needs a compiler MCP.
4. **cargo:** pipelining on the early notification, pause accounting,
   and provisional output, as `-Zheadstart` instead of an environment
   variable.

**Questions reviewers will ask** (answers in [design.md](design.md)):
- crate identity (the SVH computed from early bytes plus the HIR hash);
- retraction by deleting a file;
- polling for files rather than being told;
- the error-reporting delay (4 ms median, 249 ms p99 in cargo-0.87.1).

### 10. Measurements to redo on the current version

**Problem.** Some numbers in results.md come from the first, check-only
version, and the early write has changed since.

**How:**
- **Error delay:** the 4 ms median and 249 ms p99 are from before the
  early write stopped computing optimized MIR. Re-measure with the
  timestamps `log-rustc` records (early-metadata vs. end, for failing
  crates).
  - Also measure time to first error under contention: a dependent
    competes for CPU with the crate it started on.
- **Peak memory:** fix `bench-mem.sh` first (see below), then measure
  `cargo build`.
- **Clippy and rustdoc:** see item 7.

### 11. Tooling fixes

- **`bench-mem.sh`:**
  - It sums every rustc on the machine, including other users'. Restrict
    it to descendants of the cargo process.
  - It builds in the project directory rather than a copy.
  - It doesn't take `-c` or `::args` like `bench.sh`.
- **`bench.sh`** runs `cargo fetch` without `--locked`, so a stale
  lockfile can be rewritten. Add `--locked` once every benchmark is
  confirmed to fetch with it.
- **`log-rustc`:** under macOS's bash 3.2, `wait` doesn't wait for the
  `>(perl ...)` process substitution, so an `end` line can precede the
  last notifications. Use a named pipe, or wait on the substitution's
  PID.
- **`check-incremental.sh`:** assert that each `sed` edit changed the
  file, as `bench-incremental.sh` now does.
- **LTO:** no script exercises the path where rustc waits for rlibs
  before code generation (`-C lto=fat|thin` across crates). Add it to
  `check-swap.sh`.
- **`-Zearly-metadata` in the UI suite:** the suites above ran with the
  flag off. Forcing it on (item 5) is the real test of the loader
  changes.

### 12. Smaller items

- **Polling.** rustc polls for the full metadata. Cargo already knows
  when it's written, and could say so on stdin.
- **Memory-mapped retraction.** On Unix, a waiter notices a deleted early
  file only by polling for it.
- **`-Zthreads` nondeterminism.** lemmy's "overflow evaluating the
  requirement" warnings land on different lines from run to run, with or
  without headstart. That's upstream behavior, but it makes
  diagnostics comparisons under `-Zthreads` noisy.
- **zola.** Its build ends in one crate compiling alone for 81 s, so
  nothing can help it except making that crate faster.
