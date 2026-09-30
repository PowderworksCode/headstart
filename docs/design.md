# Design

## The idea

A crate's dependents compile against its metadata (`.rmeta`): its items'
signatures, types and trait impls, plus MIR for anything they might
evaluate at compile time, inline or instantiate. Today rustc writes that
metadata only after every function body has been type-checked and
borrow-checked. Most of what that work produces, dependents never need.

Headstart writes a second, earlier metadata file as soon as the item
interfaces are checked, before any function body is. Dependents start
from it right away, while the crate itself goes on checking its bodies.

- **`cargo check`** never needs more than that, so dependents run to
  completion on early metadata.
- **`cargo build`** also has to generate code and link. A dependent does
  all of its analysis against early metadata. It waits for the
  dependency's full metadata before code generation, because instantiating
  generic and inline functions needs their MIR. A crate that links
  (binaries, tests, proc macros, build scripts) also waits for the rlibs
  before linking. While it waits, its job slot goes to other work.

If a body turns out to be wrong, the crate still fails, and so does the
build. Dependents that started early have their work thrown away, and
their output is dropped, so a failing build reports what it reports
today. That's the "dangerous" part: dependents compile against a
promise. Whenever the build succeeds, the promise held, and their results
are exactly what they'd have been.

## rustc: `-Zearly-metadata`

### Producing early metadata

Analysis is split by a new query, `analysis_interfaces`. It runs
everything up to and including the item interface checks (well-formedness,
coherence). `analysis` runs it first, then checks every body.

The driver writes early metadata between the two, as a step of its own,
just as it writes full metadata after analysis:

1. `analysis_interfaces`.
2. `write_early_metadata`:
   - evaluate statics and synthesize async closures' by-move bodies, the
     only definitions that checking bodies would add (encoding freezes
     the definitions table). Like body checking, this runs in parallel
     under `-Zthreads`, and so does computing the MIR of consts and
     const fns for the encoder;
   - encode `libfoo-hash.early-rmeta`;
   - announce it with an `early-metadata` artifact notification.
3. `analysis`: the bodies.
4. Full metadata, and code generation, as usual.

The early write happens outside any query, like the full one, so it
doesn't need the dependency tracking of the `analysis` query. The encoder
takes the kind of metadata as a parameter. For early metadata it reads the
definitions table through accessors that depend on `analysis_interfaces`
instead of `analysis` (`TyCtxt::definitions_after_interfaces`,
`iter_local_def_id_after_interfaces`).

Crates nothing can depend on, such as binaries, write no early metadata.

### One crate hash for both files

The two files describe the same crate, so they carry the same crate hash
(SVH). A dependent records the hash of each crate it compiled against,
and anything loaded later is matched against it. That hash is computed
once, from the early metadata, with upstream's scheme: the encoded bytes
plus a supplement of the HIR hash and the tracked options. Full metadata
carries the same one.

It's a complete identity from the start:
- the early metadata's bytes cover the interface, including every
  dependency's hash;
- the HIR hash in the supplement covers every body;
- the tracked options are included too.

Full metadata is a deterministic function of exactly those inputs, so a
change to any function body changes the hash, even one that doesn't
touch the early metadata. Incremental compilation relies on this: it
uses a dependency's crate hash to decide whether results derived from it
are still valid, including code inlined or instantiated from its bodies.

### What encoding still forces

The encoder asks the query system for whatever the metadata contains, so
anything a crate's interface depends on is computed on demand, bodies
included:

- **Opaque types.** The hidden type of an `impl Trait` in a signature
  comes from type-checking the defining function's body.
- **Constants.** The encoder records the MIR (or value) of consts,
  `const fn`s and array lengths, which means building their bodies.
- **Statics.** Evaluated before the write, as above.
- **Coroutines.** `async fn` and `async` block state machines are encoded
  with their witnesses, because dependents read them to decide whether a
  future is `Send`.

Everything else waits until after the write.

### What early metadata leaves out

- **Definitions nested in other bodies.** Closures, inline consts and
  const arguments (`foo::<3>()`) inside a function body are definitions of
  their own, typed by type-checking the enclosing body. Early metadata
  encodes them only when the enclosing body is an **interface body**, one
  whose type-checking the interface itself depends on:
  - bodies the encoder records MIR for: consts, const fns and coroutines
    (`async` bodies);
  - statics;
  - functions that define an opaque type (`-> impl Trait`, `async fn`),
    and the bodies that may define a `type Alias = impl Trait`.

  A dependent reaches a body's contents only through a type or MIR that
  came from an interface body, so it can't name the left-out ones before
  its own code generation. By then it reads full metadata.

  The set is a function of the code alone. A first version instead
  encoded a nested definition whenever its body happened to be
  type-checked already, which it learned by peeking at the query cache.
  That made the metadata depend on evaluation order, and on what an
  incremental session recomputed rather than loaded. `-Zearly-metadata-verify`
  reports any left-out definition whose body was type-checked during the
  write anyway, which would be a body the set missed. The benchmark sweep
  reports none (see [results.md](results.md)).
- **Optimized MIR of functions, and their deduced parameter
  attributes.** Dependents need them only for code generation, from full
  metadata. Only coroutines' optimized MIR is in early metadata, because
  dependents compute a future's layout during analysis.

  Computing any other function's optimized MIR would type-check its body.
  It would also run the MIR inliner, which asks each dependency whether
  it has MIR for the callee. A dependency loaded from early metadata says
  no, and the query system would keep that answer after the swap to full
  metadata. With optimization on, a dependent then fails to find MIR it
  needs for code generation. `-Zearly-metadata-verify` reports any query
  that only full metadata can answer when it's asked about a crate still
  loaded from early metadata.

  A crate compiled without code generation (`cargo check`) never swaps in
  its dependencies' full metadata, so its own full metadata skips the
  reachable set too. Upstream computes it there but never reads it, and
  at opt-level 1 or more computing it runs the MIR inliner.
- **Exported symbols, cross-crate inlinability and the panic strategy.**
  Computing them collects the crate's monomorphizations, or walks its
  bodies. Early metadata doesn't compute the reachable set either, which
  decides which MIR full metadata encodes. Only code generation and
  linking read any of these, from full metadata.

### Consuming early metadata

Writing early metadata first deletes the crate's stale full metadata and
rlib. So a full `.rmeta` or `.rlib` next to early metadata is always from
the same compilation or a later one, never an earlier one.

With the flag, crate loading also considers `libfoo-hash.early-rmeta`, both
for `--extern foo=libfoo-hash.rmeta` and when searching directories for
transitive dependencies. It loads the full metadata if it exists, and the
early metadata otherwise. A crate that links and loads a dependency from
metadata also records where the dependency's rlib will be written. The
file may not exist yet.

Before code generation, `CStore::load_full_metadata` replaces every
dependency loaded from early metadata with its full metadata:

- **Waiting.** If the full file doesn't exist yet, rustc waits for it
  (see *Pausing* below). It checks that the file carries the same crate
  hash.
- **Swapping.** It loads the full blob into a new `CrateMetadata`, keeping
  what the session decided while loading the crate: its crate number
  mapping, dependency kind, and whether it's used.
- **Lookups.** From then on, the crate store's lookup returns the new
  entry. The early entry stays alive, so anything already decoded from it
  stays valid.
- **The type cache.** rustc caches types decoded from metadata by their
  position in the blob. The swapped crate's entries are dropped, because
  a position means something else in the full blob.
- **Source files.** These are imported again from the full blob's table,
  because an imported file records its index in the table it came from.

Before linking, `CStore::wait_for_rlibs` waits for the recorded rlib
paths to exist; rlibs are written atomically. With cross-crate LTO, which
reads dependencies' rlibs during code generation, it waits before code
generation instead.

### Pausing

When rustc has to wait for a dependency's full metadata or rlib:

1. It announces a `wait-metadata` artifact notification naming the file
   (the same kind for an rlib), and polls for it.
2. The build tool stops counting it as running, so its job slot can go to
   other work.
3. Once the file exists, rustc announces `resume` and continues. The
   build tool counts it as running again.

rustc never touches the jobserver for this. A resumed compilation can
briefly put the build one job over its limit, until the next job
finishes. Making it wait for a free slot instead starved it: it
competed for tokens with work started in its place, often on the
critical path (see [results.md](results.md)).

The crate graph has no cycles, so what a paused compilation waits for is
always running or queued, and waiting can't deadlock.

**Retraction.** If a crate fails after writing early metadata, its
promise is withdrawn: the early file is deleted. rustc does this when a
compilation ends with errors or panics, through linking, which is where
code generation finishes and the rlib is written. A build tool has to
do it when the compiler is killed or aborts. A compilation waiting for that crate's full metadata or
rlib sees the early metadata disappear, and stops with an error. Its
output is dropped anyway (below).

## cargo: `CARGO_HEADSTART=1`

With the variable set:

- **Every rustc compile gets `-Zearly-metadata`.** Crates with dependents
  write early metadata, and every crate can load it.
- **Dependents start on the `early-metadata` notification.**
  - Every unit rustc compiles, in check, build or test mode, starts on its
    rlib dependencies' early metadata. That includes binaries, tests,
    proc macros and build scripts.
  - Proc-macro and dylib dependencies still need a full build.
  - Cargo already pipelined `cargo build` libraries on the `metadata`
    notification. Headstart extends that to every unit, and to
    `cargo check`.
  - A unit's dependents are released once, on whichever notification
    comes first. Cargo reads the notification's `emit` field for the new
    kinds, and still recognizes full metadata by its `.rmeta` extension.
- **No waiting for the whole dependency tree.** Cargo normally makes a
  unit that links wait for the *full* build of every transitive
  dependency. Under headstart, rustc waits for the rlibs itself right
  before linking, so those edges go.
- **Pause accounting.**
  - A paused compilation (a `wait-metadata` notification) doesn't count as
    running, so its slot goes to other work.
  - When it announces `resume`, it counts as running again. Cargo starts
    no new work until the number of running jobs is back under the
    limit.
- **Retraction.** When a unit fails, cargo deletes its early metadata, in
  case rustc crashed before it could.
- **Only error-free dependencies get their output reported.** A unit that
  started before its dependencies finished is provisional. Its
  diagnostics, JSON messages and result are held until every dependency
  has finished cleanly, then emitted in their original order. If a
  dependency fails, they're dropped. A held unit still frees its job slot
  and unblocks its dependents.

  So a failing build prints the same diagnostics, JSON messages and exit
  status as today. What can differ is output that already depends on
  timing today:
  - progress lines: `Checking`/`Compiling` for dependents that started
    early, and `Finished`;
  - "waiting for other jobs to finish" and lock waits (`Blocking`);
  - the order of JSON messages across crates, which cargo doesn't
    guarantee.

With the variable unset, cargo behaves exactly as upstream.

## Risks

- **A crate's own errors surface a little later.** They're delayed by the
  early write: 4 ms for the median crate in cargo-0.87.1's build, and
  249 ms at p99 (see [results.md](results.md); measured before the
  latest changes to what the early write computes). That was one of the
  two reasons the 2019 attempt stopped ([rust-lang/rust#64112]). A
  dependent also competes for CPU with the crate it started on, which
  this figure doesn't capture.
- **Wasted work on failure.** When a crate fails, its dependents' work so
  far is thrown away. The output is still the same as today.
- **Incremental builds.** `-Zearly-metadata` is a tracked option, so
  toggling it starts a fresh incremental session. The crate hash covers
  every body (see above), so dependents' incremental results stay sound.
  `scripts/check-incremental.sh` runs a sequence of edits under `cargo
  check` and `cargo build`. It checks that each step matches the same
  step with headstart off, and that the final state matches a clean
  build.
- **Platforms.** Retraction deletes a file that dependents may have
  memory-mapped. That's fine on Unix; on Windows, deleting an open file
  can fail, and that path hasn't been tested.
- **Memory.** More compilers are alive at once, including paused ones,
  so peak memory can rise (see [results.md](results.md#peak-memory),
  measured on the first, check-only version). Cargo doesn't cap the
  number of paused compilers yet.
- **The parallel front end.** `-Zthreads` uses the same idle cores. On
  top of it, headstart adds up to 25% on real projects, less on wide
  ones, and within noise of nothing on a few (see
  [results.md](results.md)).
- **Contention.** A resumed compilation doesn't wait for a free job
  slot, and headstart keeps more compilations running. On a saturated
  machine that can slow the critical path. Cargo doesn't adjust its
  scheduling for this yet.
- **Coverage.** If the metadata needs something from a body that the
  encoder doesn't know to force, the failure would be a compiler crash
  (an ICE): a missing entry in a dependent, or a definition created after
  the table is frozen. The benchmark sweeps and `-Zearly-metadata-verify`
  are how we look for those. They're evidence, not a proof.

## Prior art

In 2019, Nicholas Nethercote moved metadata writing before type-checking
and borrow-checking in [rust-lang/rust#64112]. He measured debug and
release builds with a single metadata file. That file had to carry the
MIR dependents need for code generation, so the early write still forced
most of the analysis. He saw at most 1.07×, and abandoned the change
because "it wasn't much of a win, and it would slightly delay error
message emission"
([blog](https://blog.mozilla.org/nnethercote/2019/10/11/how-to-speed-up-the-rust-compiler-some-more-in-2019/)).

Headstart differs in two ways. Early metadata is a separate file with
only what analysis needs, and dependents wait for the full file only
before code generation. It also covers `cargo check`, which cargo didn't
pipeline at all.

David Lattimore's
["Speeding up rustc by being lazy"](https://davidlattimore.github.io/posts/2024/06/05/speeding-up-rustc-by-being-lazy.html)
(2024) proposes a pipeline whose first step writes an `.rmeta` with "only
what's needed to check dependent crates", and then finishes the error
checking. Headstart is close to that first step, with the full metadata
following in the same compilation.

[rust-lang/rust#64112]: https://github.com/rust-lang/rust/pull/64112
