# Is it ready for the compiler and cargo teams?

An assessment of the patch series in [patches/](../patches), after it was
reproduced on a 4-core container, rebased onto the 2026-10-01 masters,
cleaned up, and split into commits (see
[results.md](results.md#after-rebasing-onto-current-master-4-cores) and
[patches/README.md](../patches/README.md)).

## Verdict

**Ready for the design conversation, and for a draft PR to show with it.
Not yet ready to merge.**

- **Ready to post now:** a design post on Zulip, in t-compiler (with
  wg-compiler-performance) and t-cargo, with the series as a draft PR.
  - The idea answers the objection that stopped the 2019 attempt
    ([rust-lang/rust#64112]).
  - The gains are large on real workspaces, and they reproduce.
  - The code is in the shape upstream expects:
    - a commit series, each commit building on its own;
    - in-tree tests;
    - `fmt` and `tidy` clean;
    - an unstable flag on each side.
  - The correctness evidence is well beyond a typical prototype's.
- **Not ready to merge:**
  - The compiler side needs an MCP.
  - The headline numbers need a fresh run on a 16- and an 8-core machine
    (`scripts/bench-suite.sh`).
  - Reviewers will push on the open items below, items 1, 3 and 4 above
    all.

## What makes the case

- **Large gains where builds are chain-shaped, and on machines with idle
  cores.** On 16 cores:
  - rust-analyzer: 54% for `cargo check`, 42% for `cargo build`;
  - polars and wasmtime: 29–49%;
  - zed and lemmy: 1.3–2.7 minutes saved per clean build.
- **It reproduces, and nothing got meaningfully slower.** On 4 cores,
  twice (before and after the rebase):
  - All 21 rustc-perf benchmarks are faster by median.
  - rust-analyzer, helix and wasmtime are faster in check and build.
  - Wide builds (typst, lldap, bevy) are within noise of even.
  - Diagnostics were identical in every successful build.
- **The gain scales with the cores the build leaves idle.**
  - rust-analyzer on 4 cores: 24% for check, 13–15% for build.
  - With headstart, 3.6–3.8 of 4 slots stay busy, so 4 cores leave little
    more to gain. That is a property of the machine, and it holds for any
    scheduling improvement.
- **Correctness evidence:**
  - sweeps of all 53 rustc-perf benchmarks with `-Zearly-metadata-verify`,
    in check and build, debug and release (and `-Zthreads` before the
    cleanup);
  - 312 real-project builds;
  - identical errors and exit statuses on failure;
  - incremental edit sequences;
  - swapping to full metadata at every opt-level;
  - a dependency failing or crashing mid-build;
  - rustc's UI suite and cargo's tests pass with the flags off;
  - rustc's UI suite with `-Zearly-metadata` forced on for all 22,170
    tests. All pass but four, whose expected output depends on when bodies
    are checked; see "Done since the first review".

## Open: what reviewers will push on

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
2. **Only cargo can drive it.**
   - The loader assumes the rlib sits next to the `.rmeta`
     (`rustc_metadata/src/locator.rs`).
   - Waiting assumes the dependency's compilation runs alongside on the
     same machine. Bazel and Buck2 run rmeta actions sandboxed or remotely.
   - The MCP needs a story, even if it's "a build tool without this keeps
     today's behavior".
3. **The jobserver.**
   - A resumed compilation runs without a token, so the build can go one
     job over its limit.
   - Inside `make -j`, that breaks the jobserver's contract, not just
     cargo's count. It was a deliberate choice (waiting for a token starved
     the critical path), and it needs defending or bounding.
4. **CPU overhead on a saturated machine.**
   - With no idle core to fill, the same build spends 3–7% more rustc CPU
     time with headstart: the early write, plus more compilations competing
     for cache and memory (bevy and typst on 4 cores).
   - That's why wide builds come out even rather than slightly ahead.
   - Expect a question on whether cargo should hold back when the machine
     is already full (next-steps item 1).
5. **Memory.**
   - Paused compilers stay resident, and cargo doesn't cap them.
   - The only peak-memory numbers (−4% to +39%) are from the first,
     check-only version.
6. **The swapped crate keeps two copies of its source files** in the
   `SourceMap`, under the same stable ID. Expect questions about debuginfo
   and incremental span encoding.
7. **The interfaces build tools see:**
   - `--json=artifacts` gains three notification kinds: `early-metadata`,
     `wait-metadata` and `resume`. That interface is semi-stable, and other
     build tools parse it.
   - While a crate compiles, `libfoo-hash.rmeta.lock` and
     `libfoo-hash.rlib.lock` exist next to its outputs.
8. **Untested platforms.**
   - The locks use `std`'s file locking, which supports Windows.
   - Nothing has run on Windows, or on macOS since the locks replaced
     polling.

## Done since the first review

- **The UI suite with `-Zearly-metadata` forced on** (next-steps item 5)
  found three bug classes, now fixed and covered by tests:
  - **An error in an interface body ICEd.** The error was in a
    `const fn`, an `async fn` or a function returning `impl Trait`. It
    reached the encoder as an error type or tainted MIR, which can't be
    serialized. The early write now type-checks those bodies and builds
    their MIR before encoding, and writes nothing if that fails. 17 tests
    hit this.
  - **Async closures' by-move bodies were created too early, and in
    parallel.**
    - They were created before the enclosing item was type-checked, which
      ICEd for one nested in a const argument (2 tests).
    - They were created in parallel under `-Zthreads`, which gave their
      new `DefId`s a nondeterministic order, and could make builds
      irreproducible. They're now created as `check_crate_bodies` does:
      sequentially, after type-checking.
  - **A dependency built as metadata only was waited on for an rlib that
    would never come** (3 tests). The loader now expects an rlib only
    while the dependency holds the rlib's lock, so `--emit=obj,metadata`
    builds against it work again. The link-time wait only runs when
    linking.

  What remains is cosmetic, and only for crates with errors. An error in
  an interface body is reported before errors in other bodies (3 tests
  see the same errors in another order). A deliberate ICE's query stack
  shows the early write (1 test).
- **Two cargo bugs, found by review:**
  - linked-unit freshness, which could leave a stale binary
    (reproduced, fixed and tested);
  - scrape-examples units that are allowed to fail, which could hold
    their dependents' output forever.
- **Polling replaced by output locks.**
  - Paused compilations used to poll every 10 ms with no timeout, and
    learned that a dependency failed only when its early metadata was
    deleted. They now block on a lock the dependency holds until the file
    is written.
  - A failed or crashed dependency releases the lock without the file, so
    waiters stop with an error instead of hanging, with nothing to delete
    and no build-tool cleanup. That also removes the Windows deletion
    problem, and the cargo-side cleanup that covered crashes.
- **The hooks in `start_codegen` and `link` are gated on the flag**, so
  "nothing changes without it" is visible in the code.
- **cargo's switch is `-Zheadstart`**, a regular unstable flag (also
  `[unstable] headstart` or `CARGO_UNSTABLE_HEADSTART`), documented in
  `unstable.md`, instead of an environment variable.
- **Commit series.** The rustc patch is six commits and the cargo patch
  three, each building on its own, with messages written for reviewers.
  - The reachable-set change is the first commit, independent of the
    flag, and can be its own PR.
  - The encoder refactor is separate from the feature.
  - A new helper that shared a name with an existing `SpanEncoder` method
    was renamed.
- **In-tree tests:**
  - rustc: `tests/run-make/early-metadata` covers the swap at
    `opt-level` 0 and 2, a dependency failing mid-build, and verify
    reporting nothing.
  - cargo: `tests/testsuite/headstart.rs` covers:
    - the flag's gating;
    - passing `-Zearly-metadata`;
    - a failing dependency's dependents' output being dropped;
    - held output being released;
    - linked-unit freshness;
    - every unit kind with one and four jobs.

## What to do next

1. **Measure on 16 and 8 cores** with `scripts/bench-suite.sh`, on the
   current series. The 16-core numbers predate the last fixes and the
   cleanup, and 8 cores is the common laptop size.
2. **Measure memory and error delay** on the current version
   (next-steps items 3 and 10).
3. **Write the Zulip post and the MCP.** They should state:
   - the swap invariant;
   - the notification protocol and the lock files;
   - the other-build-tool story;
   - the jobserver choice;
   - that the gain depends on idle cores, with both the 16-core and 4-core
     numbers.
4. **Send rustc commit 1 as its own PR** any time; it doesn't need the
   rest.
5. **Rebase right before posting.** The last rebase applied cleanly.

[rust-lang/rust#64112]: https://github.com/rust-lang/rust/pull/64112
