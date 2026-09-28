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
- **`cargo build`** also has to generate code. A dependent does all of its
  analysis against early metadata, then waits for the dependency's full
  metadata before code generation, because instantiating generic and
  inline functions needs their MIR. While it waits, it gives its job slot
  back.

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
     the definitions table);
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

The two files describe the same crate, so they must carry the same crate
hash (SVH). Otherwise a dependent compiled against one and a crate loaded
through the other would see a mismatch. This rustc computes the SVH from
the encoded metadata bytes by default, and the two files' bytes differ.
With `-Zearly-metadata`, the SVH comes from the HIR instead. That's the
scheme rustc used for years, and it's still available as
`-Zmetadata-crate-hash=no`. The encoder asserts that both encodings agree.

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
- **MIR of generic and inline functions.** Dependents need it only for
  code generation, from full metadata.
- **Exported symbols, the reachable set and the panic strategy.**
  Computing them collects the crate's monomorphizations, or walks its
  bodies. Only code generation and linking read them, from full metadata.

### Consuming early metadata

With the flag, crate loading also considers `libfoo-hash.early-rmeta`, both
for `--extern foo=libfoo-hash.rmeta` and when searching directories for
transitive dependencies:

- If only one of the two files exists, that one is loaded.
- If both exist with the same crate hash, they describe the same crate,
  and the full one is loaded.
- If both exist with different hashes, one is left over from an earlier
  compilation, and the newer one is loaded.

Modification times alone don't decide, because incremental compilation
can reuse a full `.rmeta` from its cache by hard-linking it, which keeps
the old time.

Before code generation, `CStore::load_full_metadata` replaces every
dependency loaded from early metadata with its full metadata:

- **Waiting.** If the full file doesn't exist yet with the same crate
  hash, rustc waits for it (see *Pausing* below).
- **Swapping.** It loads the full blob into a new `CrateMetadata`, keeping
  what the session decided while loading the crate: its crate number
  mapping, dependency kind, and whether it's used.
- **Lookups.** From then on, the crate store's lookup returns the new
  entry. The early entry stays alive, so anything already decoded from it
  stays valid.
- **Source files.** These are imported again from the full blob's table,
  because an imported file records its index in the table it came from.

### Pausing

When rustc has to wait for a dependency's full metadata:

1. It announces a `wait-metadata` artifact notification.
2. It releases a token to the jobserver, so the build tool can run
   something else on its slot.
3. It polls for the file.
4. Before continuing, it takes a token again and announces `resume`.

This goes around the jobserver proxy, which never releases a process's
last token; pausing needs exactly that. The crate graph has no cycles, so
the oldest unfinished dependency is always running or waiting for a slot,
and waiting can't deadlock.

If the build tool writes `libfoo-hash.failed-rmeta`, the dependency failed
after writing early metadata. Its full metadata will never come, so the
waiting rustc stops with an error. Its output is dropped anyway (below).

## cargo: `CARGO_HEADSTART=1`

With the variable set:

- **Every rustc compile gets `-Zearly-metadata`.** Crates with dependents
  write early metadata, and every crate can load it.
- **Dependents start on the `early-metadata` notification.** Cargo already
  pipelines `cargo build` on the `metadata` notification. Headstart also
  pipelines `cargo check` (`BuildRunner::only_requires_rmeta` holds between
  check units), and both start on early metadata. A unit's dependents are
  released once, on whichever notification comes first. Cargo now reads
  the notification's `emit` field instead of guessing from the file
  extension.
- **Check units don't wait for their whole dependency tree.** Cargo makes
  a unit that links wait for the *full* build of every transitive
  dependency. A check build never links, so check units don't get those
  edges. Binaries in `cargo build` still wait for all rlibs.
- **Failure markers.** Cargo deletes a unit's `.failed-rmeta` marker when
  it starts, and writes it if the unit fails, so dependents waiting for
  its full metadata stop.
- **Only error-free dependencies get their output reported.** A unit that
  started before its dependencies finished is provisional. Its
  diagnostics, JSON messages and result are held until every dependency
  has finished cleanly, then emitted in their original order. If a
  dependency fails, they're dropped. A held unit still frees its job slot
  and unblocks its dependents.

  So a failing build prints the same diagnostics, JSON messages and exit
  status as today. Two kinds of progress output can differ:
  - the `Checking`/`Compiling` lines of dependents that started early;
  - "waiting for other jobs to finish", which already depends on timing
    today.

  Held JSON messages can come out in a different order across crates,
  which cargo doesn't guarantee anyway.

With the variable unset, cargo behaves exactly as upstream.

## Risks

- **A crate's own errors surface a little later.** They're delayed by the
  early write: 4 ms for the median crate in cargo-0.87.1's build, and
  249 ms at p99 (see [results.md](results.md)). This is the objection
  that stopped the 2019 attempt ([rust-lang/rust#64112]); here the cost
  is measured.
- **Wasted work on failure.** When a crate fails, its dependents' work so
  far is thrown away. The output is still the same as today.
- **Incremental builds.** `-Zearly-metadata` is a tracked option, so
  toggling it starts a fresh incremental session. Full metadata that
  incremental compilation reuses carries the same crate hash, which is
  why the crate hash, not the file's age, decides between the two files.
  `scripts/check-incremental.sh` runs a sequence of edits under `cargo
  check` and `cargo build`. It checks that each step, and the final
  state, matches a clean build.
- **Memory.** More compilers are alive at once, including paused ones,
  so peak memory can rise (see [results.md](results.md#peak-memory)).
  Cargo doesn't cap the number of paused compilers yet.
- **The parallel front end.** `-Zthreads` uses the same idle cores. On
  top of it, headstart saves much less on large builds (see
  [results.md](results.md#with-the-parallel-front-end--zthreads8)).
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
