# Is it ready for the compiler and cargo teams?

An assessment written after reproducing the results on a 4-core
container (see [results.md](results.md#reproduction-on-4-cores-claude-code-container-4-jobs)).

## Verdict

**Ready to start a conversation, not ready for review.**

- **Worth raising now:** a design post on Zulip, in t-compiler (with
  wg-compiler-performance) and t-cargo, is worth writing.
  - The idea answers the objection that stopped the 2019 attempt
    ([rust-lang/rust#64112]).
  - The gains are large on real workspaces, and they reproduce.
  - The correctness evidence is well beyond a typical prototype's.
- **Not yet an MCP or PRs.** A reviewer would stop at the points under
  "What reviewers will push on". Most are work, not open questions.

## What makes the case

- **Large gains where builds are chain-shaped, and on machines with idle
  cores.** On 16 cores:
  - rust-analyzer: 54% for `cargo check`, 42% for `cargo build`;
  - polars and wasmtime: 29–49%;
  - zed and lemmy: 1.3–2.7 minutes saved per clean build.
- **It reproduces, and nothing got meaningfully slower.**
  - On 4 cores, all 21 rustc-perf benchmarks are faster by median.
  - rust-analyzer, helix and wasmtime are faster in both check and build,
    with ranges that don't overlap. typst's check is 4% faster.
  - typst's build, lldap and bevy are within noise of even. The worst is
    bevy's check at −1%, with overlapping ranges.
  - Diagnostics were identical in every successful build.
  - Chain-shaped benchmarks save the same as on 16 cores.
- **The gain scales with the cores the build leaves idle.**
  - rust-analyzer on 4 cores: 24% for check, 15% for build.
  - Wide builds that already fill 4 cores (lldap, typst, bevy): −1% to
    +4%.
  - The schedules show why: with headstart, 3.6–3.8 of 4 slots stay busy.
    That is a property of the machine, and it holds for any scheduling
    improvement.
- **Correctness evidence:**
  - sweeps of all 53 rustc-perf benchmarks in debug, release and
    `-Zthreads`, in check and build, with `-Zearly-metadata-verify`;
  - 312 real-project builds;
  - identical errors and exit statuses on failure;
  - incremental edit sequences;
  - swapping to full metadata at every opt-level;
  - rustc's UI suite and cargo's test suite pass with the patches applied
    and the feature off.

## What reviewers will push on

Checked against the code; none of these is a known failure in a normal
cargo build.

1. **The swap invariant isn't enforced.**
   - The rule: before code generation, nothing may ask a dependency still
     loaded from early metadata a question whose answer changes after the
     swap to full metadata.
   - Only a hand-kept list of queries checks it (`FULL_METADATA_QUERIES`,
     `rustc_metadata/src/rmeta/decoder/cstore_impl.rs`), and only under
     `-Zearly-metadata-verify`.
   - One concrete hole: `-Zvalidate-mir` computes `instance_mir` for every
     body in `analysis` (`rustc_interface/src/passes.rs`, "ensuring final
     MIR is computable"). At opt-level ≥ 1 that runs the MIR inliner, which
     caches "no MIR" for dependencies still on early metadata. That's the
     same shape as real-project bug 1.
   - For upstream, reading anything early metadata omits should ICE
     loudly, and the invariant should be stated in the MCP.
2. **Retraction is by deleting a file, and waiters poll for it.**
   - Paused compilations poll every 10 ms with no timeout
     (`rustc_metadata/src/creader.rs`, the waits for full metadata and
     rlibs).
   - If a crate dies and the build tool doesn't delete its early file,
     waiters wait forever. cargo does delete it.
   - On Windows, waiters memory-map the file that has to be deleted.
   - An advisory lock held on the early file for the life of the
     compilation would cover crashes, Windows, and waking waiters without
     polling. Reviewers will want a design here, not polling.
3. **Only cargo can drive it.**
   - The loader assumes the rlib sits next to the `.rmeta`
     (`rustc_metadata/src/locator.rs`).
   - Pausing assumes the dependency's compilation runs alongside on the
     same machine. Bazel and Buck2 run rmeta actions sandboxed or remotely.
   - The MCP needs a story, even if it's "a build tool without this
     keeps today's behavior".
4. **The jobserver.**
   - A resumed compilation runs without a token, so the build can go one
     job over its limit.
   - Inside `make -j`, that breaks the jobserver's contract, not just
     cargo's count. It was a deliberate choice (waiting for a token starved
     the critical path), and it needs defending or bounding.
5. **CPU overhead on a saturated machine.** With no idle core to fill,
   the same build spends 3–7% more rustc CPU time with headstart: the
   early write, plus more compilations competing for cache and memory
   (bevy and typst on 4 cores). That's why wide builds come out even
   rather than slightly ahead. Expect a question on whether cargo should
   hold back when the machine is already full (next-steps item 1).
6. **Memory.**
   - Paused compilers stay resident, and cargo doesn't cap them.
   - The only peak-memory numbers (−4% to +39%) are from the first,
     check-only version.
7. **The swapped crate keeps two copies of its source files** in the
   `SourceMap`, under the same stable ID. Expect questions about debuginfo
   and incremental span encoding.
8. **`--json=artifacts` gains three notification kinds:**
   `early-metadata`, `wait-metadata` and `resume`. That interface is
   semi-stable, and other build tools parse it.

## Fixed in this round

Two bugs in the cargo patch, found by review:

- **Freshness of units that link.** With headstart, a binary or test
  judged a dependency fresh from the dependency's `.rmeta` alone, because
  the rule for starting early was reused for freshness. rustc's
  incremental reuse of metadata keeps the `.rmeta`'s old mtime, so a
  rebuilt rlib could leave a stale binary. Freshness now uses upstream's
  rule (`BuildRunner::only_requires_rmeta_file`).
- **Docscrape units allowed to fail.** Such a failure never confirmed
  the unit. Units that depend on it were held forever, their output never
  reported, and a failure among them could be swallowed. It could also
  leave `rustdoc` waiting on a scrape unit that had finished while held.

## What to do before the MCP

In order:

1. **Keep the rebase current.** Both patches were rebased onto the
   2026-10-01 masters without conflicts, and the results held (results.md,
   "After rebasing onto current master"). Rebase again right before
   posting.
2. **Split the rustc patch into a commit series** that reads on its own:
   - Move the encoder loop bodies into `encode_def_id` and
     `encode_mir_for`. This is a pure refactor; `git diff -w` shows about
     half of `encoder.rs`'s churn is indentation.
   - **Skip the reachable set in full metadata without codegen.** This
     is independent of headstart and about 3 lines; today it's gated on
     `-Zearly-metadata`. It can land first, on its own.
   - Add the `analysis_interfaces` query.
     - It renames the `type_check_crate` self-profile label; say so.
   - Add `-Zearly-metadata`.
   - Gate the link-time and codegen-time hooks (`wait_for_rlibs`,
     `load_full_metadata`) on the flag, so that "nothing changes without
     it" is visible in the diff.
3. **In-tree tests:**
   - rustc: a run-make test for the swap, and for retraction; UI tests
     for `-Zearly-metadata-verify`; the UI suite run once with
     `-Zearly-metadata` forced on.
   - cargo: tests for held output, retraction, pause accounting, and
     linked-unit freshness.
   - cargo's switch should be `-Zheadstart`, not an environment variable.
4. **Numbers reviewers will ask for:**
   - `cargo build` peak memory on the big projects;
   - error delay on the current version;
   - timings at 8 jobs, the common laptop size;
   - the net over `-Zthreads`, which overlaps.
   See next-steps items 2–4 and 10.
5. **The write-up:** the Zulip post, then a compiler MCP for
   `-Zearly-metadata` and a cargo unstable feature. It should state:
   - the swap invariant;
   - the notification protocol;
   - retraction, and the other-build-tool story;
   - Windows;
   - that the gain depends on idle cores, with both the 16-core and
     4-core numbers.

[rust-lang/rust#64112]: https://github.com/rust-lang/rust/pull/64112
